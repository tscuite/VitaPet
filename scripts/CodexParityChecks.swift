// Run scripts/check_usage_ui.sh. Compares the actual port to separately compiled upstream sources.
import Foundation
import Localization
@testable import UsageMonitor
@testable import CodeNotchReference

@main
struct CodexParityChecks {
    static func main() async throws {
        Localization.L10n.locale = "en"
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Modules/UsageMonitor/Tests/Fixtures")
        func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: directory.appendingPathComponent("codex-\(name).json"))
        }
        var comparisons = 0
        func windows(_ data: Data, extras: Bool = true) throws {
            let reference = try? CodeNotchReference.CodexUsage.windows(from: data, now: now, includeExtras: extras)
            let reading = try? UsageParsing.parse(data, provider: .codex, now: now,
                                                  codexSettings: UsageCodexSettings(showExtraLimits: extras))
            precondition((reference == nil) == (reading == nil), "Upstream/port success must agree")
            guard let reference, let reading else { comparisons += 1; return }
            precondition(reference.count == reading.limits.count, "Window count")
            for (a, b) in zip(reference, reading.limits) {
                precondition(a.id == b.id && a.label == b.title && a.group == b.group, "Window identity and labels")
                precondition(a.usedFraction == b.usedFraction && a.resetsAt == b.resetsAt && a.duration == b.duration, "Window values and resets")
                precondition(a.used == b.used && a.remaining == b.remaining, "Credit amounts")
                precondition(a.summary == UsageTooltipCopy.summary(b), "Used/left display")
                precondition(a.usagePace(now: now)?.summary == b.usagePace(now: now)?.summary, "Usage pace")
            }
            precondition(reading.headline?.id == reference.first(where: { $0.id == "primary" })?.id,
                         "A weekly or extra limit cannot become the primary ring")
            precondition(reading.plan == CodeNotchReference.CodexUsage.plan(from: data), "Plan")
            comparisons += 1
        }
        try windows(fixture("usage"))
        try windows(fixture("usage"), extras: false)
        for seconds in [0, 900, 18000, 86400, 604800, 2592000, 345600] {
            for percent in [0.0, 0.03, 0.5, 9.5, 99.6, 100, 104] {
                let data = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent),\"limit_window_seconds\":\(seconds),\"reset_after_seconds\":600}}}".utf8)
                try windows(data)
            }
        }
        for json in [
            #"{}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":null},"secondary_window":{"used_percent":42,"limit_window_seconds":604800}}}"#,
            #"{"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":50}}}]}"#,
            #"{"code_review_rate_limit":{"primary_window":false,"secondary_window":{"used_percent":10}}}"#,
            #"{"rate_limit":"bad","additional_rate_limits":["bad",{"metered_feature":"SPARK","rate_limit":{"primary_window":{"used_percent":22}}}]}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":true},"secondary_window":{"used_percent":0}}}"#,
            #"{"spend_control":{"individual_limit":{"limit":"1000","used":"374.92","used_percent":37.492,"reset_at":1780003600}}}"#
        ] {
            try windows(Data(json.utf8))
            try windows(Data(json.utf8), extras: false)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for data in [try fixture("profile"), Data("{}".utf8), Data(#"{"stats":{"daily_usage_buckets":[{"start_date":"2026-05-28","tokens":0}]}}"#.utf8)] {
            let a = try CodeNotchReference.CodexUsage.profileUsage(from: data)
            let b = try UsageMonitor.CodexUsage.profileUsage(from: data)
            let sameStatistics = try encoder.encode(a) == encoder.encode(b)
            let sameBuckets = try encoder.encode(a.last30Days(now: now, calendar: calendar)) == encoder.encode(b.last30Days(now: now, calendar: calendar))
            precondition(sameStatistics, "All account statistics")
            precondition(sameBuckets, "30-day chart")
            precondition(a.usageToday(now: now, calendar: calendar) == b.usageToday(now: now, calendar: calendar), "Today: missing is pending, present zero is zero")
            precondition(a.usageInLast30Days(now: now, calendar: calendar) == b.usageInLast30Days(now: now, calendar: calendar), "30-day total")
        }
        for data in [try fixture("resets"), Data("{}".utf8), Data("[]".utf8)] {
            let a = try CodeNotchReference.CodexUsage.resetCredits(from: data).unexpired(at: now)
            let b = try UsageMonitor.CodexUsage.resetCredits(from: data).unexpired(at: now)
            precondition(a.availableCount == b.availableCount && a.nextExpiry == b.nextExpiry, "Reset total and expiry")
            precondition(a.credits.map(\.id) == b.credits.map(\.id), "Reset credit list")
        }
        for value in [0.0, 0.00001, 0.0003, 0.005, 0.095, 0.29, 0.4999, 0.7999, 0.996, 0.9999, 1, 1.25] {
            precondition(UsagePercent.text(for: value) == CodeNotchReference.Percent.text(for: value), "Ring percentage")
            let a = CodeNotchReference.Percent.halves(for: value), b = UsagePercent.halves(for: value)
            precondition(a.used == b.used && a.left == b.left, "Rounded used/left halves")
        }
        for seconds in [-10.0, 0, 1, 59.4, 59.9, 60, 3040, 3580, 3600, 200000, 900000, 2592000] {
            let date = now.addingTimeInterval(seconds)
            for format in [UsageResetTimeFormat.automatic, .remaining] {
                let original: CodeNotchReference.ResetTimeFormat = format == .automatic ? .automatic : .remaining
                precondition(UsageResetCopy.text(for: date, now: now, calendar: calendar, format: format, locale: calendar.locale!)
                    == CodeNotchReference.ResetCopy.text(for: date, now: now, calendar: calendar, format: original, locale: calendar.locale!), "Reset text")
            }
        }
        var schedules = 0
        for busy in [false, true] {
            for rollover in [false, true] {
                for waited in [-1.0, 0, 14.99, 15, 29.99, 30, 299.99, 300, 900] {
                    let original = ReferenceSchedule.shouldRefresh(isBusy: busy, sinceLastAttempt: waited,
                        idleInterval: 300, busyInterval: 30, resetDue: rollover)
                    let port = UsageRefreshSchedule.shouldRefresh(isBusy: busy, sinceLastAttempt: waited,
                        idleInterval: UsageRefreshSchedule.idleInterval, busyInterval: UsageRefreshSchedule.busyInterval,
                        resetDue: rollover)
                    precondition(original == port, "Scheduled fetch agrees with unmodified upstream decision")
                    for spacing in [15.0, 30] {
                        precondition(ReferenceSchedule.shouldRefreshOnEvent(sinceLastRefresh: waited, spacing: spacing)
                            == UsageRefreshSchedule.shouldRefreshOnEvent(sinceLastRefresh: waited, spacing: spacing), "Event throttling")
                        schedules += 1
                    }
                    schedules += 1
                }
            }
        }
        for last in [nil, now.addingTimeInterval(-10), now] {
            for boundary in [nil, now.addingTimeInterval(-11), now.addingTimeInterval(-10), now, now.addingTimeInterval(1)] {
                let a = ProviderSnapshot(windows: [LimitWindow(id: "primary", label: "Session", resetsAt: boundary)])
                let b = UsageReading(provider: .codex, limits: [UsageLimit(id: "primary", title: "Session", resetsAt: boundary)])
                precondition(ReferenceSchedule.hasWindowRolledOver(in: [a], since: last, at: now)
                    == UsageRefreshSchedule.hasWindowRolledOver(in: [b], since: last, at: now), "Rollover boundary")
                schedules += 1
            }
        }
        let activityFixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: activityFixture) }
        for events in [["task_started"], ["task_started", "item_completed"], ["task_started", "task_complete"], ["task_complete", "task_started"], ["task_started", "turn_aborted"], []] {
            let data = events.map { "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\($0)\"}}\n" }.joined()
            // Force backward windows, including a lifecycle record split at the scanner's slice boundary.
            for padding in [0, 262_120, 524_240, 1_048_600] {
                try Data((data + String(repeating: " ", count: padding)).utf8).write(to: activityFixture)
                let a = CodeNotchReference.CodexRolloutActivity.state(from: activityFixture)
                let b = UsageMonitor.CodexRolloutActivity.state(from: activityFixture)
                precondition((a == .busy) == (b == .busy) && (a == .success) == (b == .success), "Original bounded activity scanner")
            }
        }
        precondition(UsageRefreshSchedule.tickInterval == 15 && UsageRefreshSchedule.staleAfter == 900
            && UsageRefreshSchedule.onLookInterval == 15 && UsageRefreshSchedule.deadline == 60, "Shipped upstream defaults")
        print("PASS: \(schedules) same-input scheduling/event/reset decisions and 24 activity-tail cases agree with CodeNotch 1.20.0.")
        precondition(UsageTokenFormat.tokens(123456789) == "123.5M")
        precondition(UsageTokenFormat.tokens(12500) == "12K") // Original printf rounding, not a replacement formatter.
        precondition(UsageTokenFormat.duration(seconds: 3671) == "1h 1m")
        precondition(UsageTokenFormat.days(14) == "14d")
        print("PASS: \(comparisons) same-response window comparisons against CodeNotch 1.20.0 / 6e8b0f8; token statistics/30-day chart, resets, percentages, usage pace and reset text agree.")
        if ProcessInfo.processInfo.environment["VITAPET_VERIFY_LIVE_CODEX"] == "1" {
            do { try await liveCodexCheck() }
            catch {
                print("FAIL: live Codex comparison unavailable: \((error as? UsageFailure)?.errorDescription ?? "unsupported live response"). No credential or response body was logged.")
                exit(2)
            }
        }
    }

    /// Explicit-only: one read-only live cycle, same response to both parsers, no response persisted.
    static func liveCodexCheck() async throws {
        struct Saved: Decodable { let settings: UsageBarSettings; let retryAfter: [String: Date] }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VitaPet/usage-monitor.json")
        let saved = try JSONDecoder().decode(Saved.self, from: UsageCredentials.file(path))
        guard saved.settings.monitoringEnabled, saved.settings.providers.contains(.codex) else {
            print("SKIP: live Codex check requires existing selected-source opt-in; no credentials read."); return
        }
        if let retry = saved.retryAfter["codex"], retry > Date() {
            print("SKIP: existing Codex retry deadline is still active; no credentials read."); return
        }
        let context = try UsageCredentials.codexRequest()
        guard !context.isExpired else { throw UsageFailure.credentialExpired }
        let settings = UsageCodexSettings.read()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: UsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let usage = try await UsageTransport.data(context.request, session: session)
        var resetRequest = context.request
        resetRequest.url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        resetRequest.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        async let resetData = try? UsageTransport.data(resetRequest, session: session)
        let now = Date()
        let a = try CodeNotchReference.CodexUsage.windows(from: usage, now: now, includeExtras: settings.showExtraLimits)
        let b = try UsageParsing.parse(usage, provider: .codex, now: now, codexSettings: settings)
        precondition(a.count == b.limits.count && a.map(\.id) == b.limits.map(\.id), "Live window identity")
        for (x, y) in zip(a, b.limits) {
            precondition(x.usedFraction == y.usedFraction && x.resetsAt == y.resetsAt && x.duration == y.duration
                && x.summary == UsageTooltipCopy.summary(y), "Same live response values/reset/display")
        }
        precondition(b.plan == CodeNotchReference.CodexUsage.plan(from: usage), "Live plan")
        var profileRequest = context.request
        profileRequest.url = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!
        let profile = try? await UsageTransport.data(profileRequest, session: session)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var profileCompared = false, resetsCompared = false
        if let profile {
            let a = try CodeNotchReference.CodexUsage.profileUsage(from: profile)
            let b = try UsageMonitor.CodexUsage.profileUsage(from: profile)
            let equal = try encoder.encode(a) == encoder.encode(b)
            precondition(equal, "Live account statistics and chart buckets")
            profileCompared = true
        }
        if let data = await resetData {
            let a = try CodeNotchReference.CodexUsage.resetCredits(from: data)
            let b = try UsageMonitor.CodexUsage.resetCredits(from: data)
            precondition(a.availableCount == b.availableCount && a.nextExpiry == b.nextExpiry, "Live unused resets")
            resetsCompared = true
        }
        print("PASS: live selected Codex account, \(a.count) quota windows match upstream; profile compared=\(profileCompared), resets compared=\(resetsCompared). Raw responses stayed in memory only.")
    }
}
