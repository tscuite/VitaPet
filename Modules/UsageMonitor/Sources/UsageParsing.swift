import Foundation
import CoreFoundation

// Endpoint schemas adapted from CodeNotch (MIT); see THIRD_PARTY_NOTICES.md.
// Zero is a valid reading; missing fields never become zero. Values above 100% remain intact.
enum UsageParsing {
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFailure.invalidResponse
        }
        return root
    }
    static func number(_ value: Any?, allowNegative: Bool = false) -> Double? {
        let result: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { result = n.doubleValue }
        else if let s = value as? String, s.count < 64 { result = Double(s) }
        else { result = nil }
        return result.flatMap { $0.isFinite && (allowNegative || $0 >= 0) ? $0 : nil }
    }
    static func date(_ value: Any?) -> Date? {
        if let n = number(value) {
            let seconds = n > 10_000_000_000 ? n / 1000 : n
            return seconds <= 253_402_300_799 ? Date(timeIntervalSince1970: seconds) : nil
        }
        guard let s = value as? String, s.count < 80 else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0); day.dateFormat = "yyyy-MM-dd"
        return day.date(from: s)
    }
    static func parse(_ data: Data, provider: UsageProviderID, now: Date = Date(),
                      codexSettings: UsageCodexSettings = UsageCodexSettings()) throws -> UsageReading {
        let root = try object(data)
        var limits: [UsageLimit] = []
        var detail: String?
        var headlineID: String?
        var plan: String?
        func add(_ id: String, _ title: String, _ value: Double?, _ reset: Any? = nil) {
            guard let value else { return }
            limits.append(UsageLimit(id: id, title: title, usedFraction: value, resetsAt: date(reset)))
        }
        func percent(_ value: Any?) -> Double? { number(value).map { $0 / 100 } }
        func bucket(_ value: Any?, _ id: String, _ title: String, _ reset: Any?) {
            guard let b = value as? [String: Any], b["enabled"] as? Bool != false,
                  let used = number(b["used"]), let cap = number(b["limit"]), cap > 0 else { return }
            add(id, title, used / cap, reset)
        }
        switch provider {
        case .codex:
            return UsageReading(provider: .codex, status: .ready,
                                limits: try CodexUsage.windows(from: data, now: now, includeExtras: codexSettings.showExtraLimits),
                                updatedAt: now, headlineID: "primary", plan: CodexUsage.plan(from: data),
                                codexSettings: codexSettings)
        case .claude:
            for (index, w) in ((root["limits"] as? [[String: Any]]) ?? []).prefix(20).enumerated() {
                guard let kind = w["kind"] as? String, kind.count < 80 else { continue }
                add(kind + "_\(index)", kind.replacingOccurrences(of: "_", with: " "), percent(w["percent"]), w["resets_at"])
            }
            for (key, kind, title) in [("five_hour", "session", "5h session"), ("seven_day", "weekly_all", "Weekly · all models"),
                                       ("seven_day_sonnet", "weekly_sonnet", "Weekly · Sonnet"), ("seven_day_opus", "weekly_opus", "Weekly · Opus")] {
                guard !limits.contains(where: { $0.id.hasPrefix(kind + "_") }), let w = root[key] as? [String: Any] else { continue }
                add(kind, title, percent(w["utilization"]), w["resets_at"])
            }
            limits.sort { ($0.id.hasPrefix("session") ? 0 : 1) < ($1.id.hasPrefix("session") ? 0 : 1) }
        case .glm:
            // GLM rides errors in under HTTP 200 ({"code":401,"success":false}); the envelope is read first.
            let code = number(root["code"], allowNegative: true)
            if root["success"] as? Bool != true, let code, code != 200 {
                if code == 401 || code == 403 { throw UsageFailure.notConnected }
                if code == 429 { throw UsageFailure.rateLimited(now.addingTimeInterval(60)) }
                throw UsageFailure.invalidResponse
            }
            let payload = root["data"] as? [String: Any] ?? [:]
            plan = (payload["level"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            for entry in (payload["limits"] as? [[String: Any]] ?? []).prefix(20) {
                // Without a percentage there is nothing to draw; a bare count would invent a scale.
                guard let pct = number(entry["percentage"]) else { continue }
                let type = entry["type"] as? String
                let unit = number(entry["unit"]).flatMap(Int.init), count = number(entry["number"]).flatMap(Int.init)
                // Identity comes from the window length, not the meter: token plans answer TOKENS_LIMIT,
                // credit plans CREDIT_LIMIT, and both encode (hours,5)/(weeks,1) the same way.
                let id: String
                if type == "TIME_LIMIT" { id = "mcp" }
                else if unit == 3, count == 5 { id = "session" }
                else if unit == 6, count == 1 { id = "weekly" }
                else if let unit, let count { id = "window-\(unit)x\(count)" }
                else { id = type?.lowercased() ?? "unknown" }
                let title: String
                switch id {
                case "session": title = "Current session"
                case "weekly": title = "Weekly"
                case "mcp": title = "MCP (1 month)"
                default:
                    if id.hasPrefix("window-"), let count { title = unit == 3 ? "Usage (\(count) h)" : "Usage (\(count) wk)" }
                    else { title = "Usage" }
                }
                let duration: TimeInterval? = count.flatMap { n in
                    switch unit {
                    case 3: return Double(n) * 3600
                    case 6: return Double(n) * 7 * 86400
                    default: return nil
                    }
                }
                limits.append(UsageLimit(id: id, title: title, usedFraction: pct / 100,
                                         resetsAt: date(entry["nextResetTime"]), duration: duration))
            }
            // Session first, then weekly, then MCP — the order the plan's own panel leads with.
            func rank(_ id: String) -> Int {
                switch id { case "session": return 0; case "weekly": return 1; case "mcp": return 2; default: return 3 }
            }
            limits.sort { let (a, b) = (rank($0.id), rank($1.id)); return a == b ? $0.id < $1.id : a < b }
            headlineID = "session"
        case .copilot:
            guard let quotas = root["quota_snapshots"] as? [String: Any] else { throw UsageFailure.invalidResponse }
            var unlimitedCount = 0
            var hasZeroEntitlement = false
            for (key, title) in [("premium_interactions", "Premium requests"), ("chat", "Chat requests"), ("completions", "Completions")] {
                guard let q = quotas[key] as? [String: Any] else { continue }
                let reset = q["reset_date"] ?? q["reset_at"] ?? q["resets_at"] ?? root["quota_reset_date"]
                if q["unlimited"] as? Bool == true {
                    limits.append(UsageLimit(id: key, title: title + " · unlimited", resetsAt: date(reset)))
                    unlimitedCount += 1
                    continue
                }
                let cap = number(q["entitlement"])
                if cap == 0 {
                    // Token-billed seats can return 100% remaining with a zero-denominator placeholder.
                    hasZeroEntitlement = true
                    continue
                }
                if let cap, let used = number(q["used"]) {
                    add(key, title, used / cap, reset)
                } else if (q["entitlement"] == nil || q["entitlement"] is NSNull || cap != nil),
                          let remaining = number(q["percent_remaining"], allowNegative: true), remaining <= 100 {
                    // Negative remaining percentages represent overage; do not clamp away consumed quota.
                    add(key, title, (100 - remaining) / 100, reset)
                } else if let cap, let remaining = number(q["remaining"]) {
                    add(key, title, max(0, cap - remaining) / cap, reset)
                } else if let remaining = number(q["remaining"]) {
                    limits.append(UsageLimit(id: key, title: title + " · \(remaining.formatted()) remaining", resetsAt: date(reset)))
                }
            }
            headlineID = limits.first { $0.usedFraction != nil }?.id
            if headlineID == nil {
                if root["token_based_billing"] as? Bool == true {
                    detail = "Copilot uses token-based billing; this endpoint reported no quota percentage."
                } else if unlimitedCount > 0, unlimitedCount == limits.count, !hasZeroEntitlement {
                    detail = "Copilot reported unlimited quotas; no quota percentage is available."
                } else if hasZeroEntitlement || !limits.isEmpty {
                    detail = "Copilot did not report a usable quota limit or percentage."
                }
            }
        case .ollama:
            if let blocks = root["limits"] as? [String: Any] {
                // Legacy quota shape; activity.period.ending_at is the range end, NOT a quota reset.
                for (key, title) in [("monthly", "Monthly usage"), ("session", "Session usage"), ("weekly", "Weekly usage")] {
                    if let b = blocks[key] as? [String: Any] { add(key, title, number(b["usage"])) }
                }
            } else if let totals = root["totals"] as? [String: Any] {
                // 2026-11: /api/usage answers with spend aggregates only (no quota anymore);
                // spend shares the local-DeepSeek fixed US$100 budget convention.
                let title = ["7d": "Last 7 days", "30d": "Last 30 days"][root["range"] as? String ?? "7d"] ?? "Recent spend"
                add("spend", title, number(totals["usage_usd"]).map { $0 / 100 })
            } else {
                throw UsageFailure.invalidResponse
            }
        case .deepseek:
            throw UsageFailure.invalidResponse // Local Pi costs are never derived from a shared account balance.
        }
        guard !limits.isEmpty || detail != nil else { throw UsageFailure.invalidResponse }
        return UsageReading(provider: provider, status: .ready, limits: limits, updatedAt: now,
                            detail: detail, headlineID: headlineID, plan: plan)
    }
}
