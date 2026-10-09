import AppKit
import Foundation
@testable import UsageMonitor

private actor LocalReadCount {
    var value = 0
    func increment() { value += 1 }
}

@MainActor
func piLocalSpendChecks(_ root: URL) async throws {
    let home = root.appendingPathComponent("local-spend-home")
    let agent = home.appendingPathComponent(".config/pi")
    let sessions = agent.appendingPathComponent("sessions/project")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("original.jsonl")
    let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10T12:00:00Z, across a DST change.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let calendar = cal
    let today = calendar.startOfDay(for: now)
    let thirtyDaysAgo = try Date.ISO8601FormatStyle().parse("2026-02-08T12:00:00Z")
    let sevenDaysAgo = try Date.ISO8601FormatStyle().parse("2026-03-03T12:00:00Z")
    precondition(now.timeIntervalSince(sevenDaysAgo) == 7 * 86_400 && now.timeIntervalSince(thirtyDaysAgo) == 30 * 86_400)
    let reader = PiLocalSpend()
    func load(_ budget: Int = PiLocalSpend.maxFileBytes, env: [String: String] = [:]) async throws -> UsageLocalSpend {
        let result = try await reader.fetch(home: home, env: env, now: now, calendar: calendar, byteBudget: budget)
        let reading = try result.result.get()
        precondition(reading.provider == .deepseek && reading.limits.isEmpty && reading.status == .ready)
        return reading.localSpend!
    }
    func row(_ id: String, _ date: Date, _ cost: Any?, model: String = "deepseek-v4-pro") -> [String: Any] {
        var usage: [String: Any] = ["input": 100, "output": 20, "cacheRead": 50, "cacheWrite": 0, "reasoning": 10]
        if let cost { usage["cost"] = ["total": cost] }
        return ["type": "message", "id": id, "timestamp": date.ISO8601Format(), "message": [
            "role": "assistant", "provider": "CF", "model": model, "responseId": "gateway-reuses-this-id",
            "timestamp": date.timeIntervalSince1970 * 1000, "usage": usage, "stopReason": "stop",
            "content": [["type": "text", "text": "private-fixture-body-do-not-retain"]]
        ]]
    }
    func save(_ rows: [[String: Any]], at url: URL = file, id: String = "session-a", tail: String = "") throws {
        let header: [String: Any] = ["type": "session", "version": 3, "id": id, "timestamp": now.ISO8601Format()]
        var data = Data()
        for row in [header] + rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)); data.append(10)
        }
        data.append(Data(tail.utf8)); try data.write(to: url, options: .atomic)
    }
    let empty = try await load()
    precondition(empty.total.usd == nil && empty.today.usd == nil && !empty.incomplete && empty.discoveredFiles == 0,
                 "No logs is distinguishable from missing prices, and never $0")
    let rows = [row("a", today, "0.10"), row("b", today, "0.20"), row("c", thirtyDaysAgo, "0.30"),
                row("7-day-cutoff", sevenDaysAgo, "0.25"), row("before-7-day-cutoff", sevenDaysAgo.addingTimeInterval(-1), "0.15"),
                row("yesterday", today.addingTimeInterval(-1), "0.05"),
                row("d", thirtyDaysAgo.addingTimeInterval(-1), "0.40"), row("future", now.addingTimeInterval(1), 900),
                row("other", today, 900, model: "gpt-5"), row("lookalike", today, 900, model: "not-deepseek-v4-pro")]
    try save(rows)
    var spend = try await load()
    precondition(spend.today.usd == Decimal(string: "0.30") && spend.last7Days.usd == Decimal(string: "0.60")
                 && spend.last30Days.usd == Decimal(string: "1.05") && spend.total.usd == Decimal(string: "1.45"),
                 "Rolling 168/720-hour cutoffs include prior-week/month costs across DST; today still uses local midnight")
    var differentWeekStart = calendar; differentWeekStart.firstWeekday = calendar.firstWeekday == 1 ? 2 : 1
    let sameWindows = try await reader.fetch(home: home, env: [:], now: now, calendar: differentWeekStart, byteBudget: 0)
    let sameSummary = try sameWindows.result.get().localSpend
    precondition(sameSummary == spend, "Week-start preference must not alter rolling windows")
    let advanced = try await reader.fetch(home: home, env: [:], now: now.addingTimeInterval(0.5), calendar: calendar, byteBudget: 0)
    let aged = try advanced.result.get().localSpend!
    precondition(aged.today.usd == Decimal(string: "0.30") && aged.last7Days.usd == Decimal(string: "0.35")
                 && aged.last30Days.usd == Decimal(string: "0.75"), "Cached records age out at the exact rolling cutoff without rescanning")
    let clone = sessions.appendingPathComponent("clone.jsonl")
    try save(rows, at: clone, id: "new-cloned-session")
    spend = try await load()
    precondition(spend.total.usd == Decimal(string: "1.45") && spend.total.records == 7
                 && spend.total.recorded == 7 && spend.today.recorded == 2
                 && spend.discoveredFiles == 2 && spend.scannedFiles == 2,
                 "Fork/clone history and source counters are deduplicated; reused responseId is not a request ID")
    try FileManager.default.removeItem(at: clone)
    spend = try await load(0)
    precondition(spend.total.usd == Decimal(string: "1.45") && !spend.incomplete, "Unchanged files use cached metadata, without reading log bytes")
    try save(rows + [row("a", today.addingTimeInterval(1), "0.50")])
    spend = try await load()
    precondition(spend.total.usd == Decimal(string: "1.95"), "Appending a real new request is not deduplicated by a reused short entry ID")
    try save([row("replacement", today, 3)])
    spend = try await load()
    precondition(spend.total.usd == 3 && spend.total.records == 1, "Truncation/replacement discards the old file's contribution")
    try FileManager.default.removeItem(at: file)
    spend = try await load()
    precondition(spend.total.usd == nil, "Deleted logs don't remain in retained-record totals")

    var actual = row("actual", today, "5e-7", model: "gateway-alias")
    var message = actual["message"] as! [String: Any]; message["responseModel"] = "vendor/DeepSeek-v4-flash"; actual["message"] = message
    var misrouted = row("not-actual", today, 100)
    message = misrouted["message"] as! [String: Any]; message["responseModel"] = "gpt-5"; misrouted["message"] = message
    var usageEntry = row("usage-entry", today, "0.01")["message"] as! [String: Any]
    usageEntry["type"] = "usage"; usageEntry["id"] = "usage-entry"; usageEntry["timestamp"] = today.ISO8601Format()
    var components = row("components", today, nil)
    message = components["message"] as! [String: Any]
    var usage = message["usage"] as! [String: Any]
    usage["cost"] = ["input": "0.001", "output": "0.002", "cacheRead": "0.0001", "cacheWrite": 0]
    message["usage"] = usage; components["message"] = message
    try save([actual, misrouted, usageEntry, components,
              row("unknown", today, 0, model: "deepseek-unknown-fixture"),
              row("invalid", today, "NaN", model: "deepseek-unknown-fixture")])
    spend = try await load()
    precondition(spend.today.usd == Decimal(string: "0.0131005") && spend.total.records == 5 && spend.total.unpriced == 2,
                 "Actual DeepSeek model, standalone usage, component costs, scientific decimals and unknown zero/invalid pricing")
    let pricing: [String: Any] = ["input": 2, "output": 4, "cacheRead": 0.5, "cacheWrite": 5]
    func priceFile(_ pricing: [String: Any], models: [String] = ["deepseek-v4-pro", "deepseek-unknown-fixture"]) throws {
        let json: [String: Any] = ["providers": ["CF": ["apiKey": "!must-not-execute", "baseUrl": "https://gateway.invalid",
            "models": models.map { ["id": $0, "cost": pricing] }]]]
        try JSONSerialization.data(withJSONObject: json).write(to: agent.appendingPathComponent("models.json"))
    }
    try priceFile(pricing)
    spend = try await load(0)
    precondition(spend.total.unpriced == 0 && spend.total.usd == Decimal(string: "0.0137105")
                 && spend.total.recorded == 3 && spend.total.configured == 2 && spend.total.reference == 0,
                 "Existing model prices work for gateway aliases without re-reading logs; cacheRead/reasoning are not counted twice")
    var tiered = pricing; tiered["tiers"] = [["inputTokensAbove": 100, "input": 4, "output": 8, "cacheRead": 1, "cacheWrite": 10]]
    try priceFile(tiered)
    spend = try await load(0)
    precondition(spend.total.usd == Decimal(string: "0.0143205"), "Configured Pi pricing tiers; recorded costs still take precedence")
    // The four gateway IDs in the user's model configuration, with no cost metadata.
    let gatewayModels = ["custom-modelscope/deepseek-ai/DeepSeek-V4.1-Flash", "custom-tencent/deepseek-v4-flash",
                         "custom-tencent/deepseek-v4-pro", "custom-aliyun/deepseek-v4-pro-0813"]
    let unpricedConfig: [String: Any] = ["providers": ["CF": ["models": gatewayModels.map { ["id": $0] }]]]
    try JSONSerialization.data(withJSONObject: unpricedConfig).write(to: agent.appendingPathComponent("models.json"))
    let gatewayRows = gatewayModels.enumerated().map { row("gateway-\($0.offset)", today, 0, model: $0.element) }
    try save(gatewayRows + [row("pi-reported", today, "0.123", model: gatewayModels[0])])
    spend = try await load()
    // CC Switch PEAK price goldens: Flash (100×.30 + 20×1.20 + 50×.006)/1M = .0000543;
    // Pro (100×1.32 + 20×3.96 + 50×.044)/1M = .0002134. Pi input is already fresh.
    precondition(spend.today.usd == Decimal(string: "0.1235354") && spend.total.reference == 4
                 && spend.total.recorded == 1 && spend.total.configured == 0 && spend.total.unpriced == 0,
                 "Zero Pi placeholders use cc-switch model prices; reported Pi amounts still win")
    try save(gatewayRows, at: clone, id: "clone-with-reference-pricing")
    spend = try await load()
    precondition(spend.today.usd == Decimal(string: "0.1235354") && spend.total.reference == 4, "Reference estimates are also deduplicated")
    try FileManager.default.removeItem(at: clone)
    try priceFile(pricing, models: gatewayModels)
    spend = try await load(0)
    precondition(spend.today.usd == Decimal(string: "0.12422") && spend.total.reference == 0
                 && spend.total.configured == 4 && spend.total.recorded == 1,
                 "Configured prices replace estimates without rescanning or changing recorded fees")

    var routed = row("routed", today, 0, model: gatewayModels[2])
    message = routed["message"] as! [String: Any]; message["responseModel"] = "deepseek-v4-pro-0813"; routed["message"] = message
    var differentFamily = row("different-family", today, 0, model: gatewayModels[2])
    message = differentFamily["message"] as! [String: Any]; message["responseModel"] = "deepseek-flash"; differentFamily["message"] = message
    var futureModel = row("future-model", today, 0, model: gatewayModels[2])
    message = futureModel["message"] as! [String: Any]; message["responseModel"] = "deepseek-v4-pro-9999"; futureModel["message"] = message
    try save([routed, differentFamily, futureModel])
    spend = try await load()
    precondition(spend.today.usd == Decimal(string: "0.0003593") && spend.total.configured == 1
                 && spend.total.reference == 1 && spend.total.unpriced == 1,
                 "A known actual alias keeps the gateway rate; a different/unknown actual model never inherits the requested model price")
    let overridden: [String: Any] = ["providers": ["CF": ["models": [["id": "deepseek-v4-pro-0813", "cost": pricing]],
        "modelOverrides": ["deepseek-v4-pro-0813": ["cost": ["output": 8]]]]]]
    try JSONSerialization.data(withJSONObject: overridden).write(to: agent.appendingPathComponent("models.json"))
    try save([routed])
    spend = try await load()
    precondition(spend.today.usd == Decimal(string: "0.000385") && spend.today.configured == 1,
                 "Exact actual-model config with partial overrides is merged before reference pricing")
    try FileManager.default.removeItem(at: agent.appendingPathComponent("models.json"))
    for (model, expected) in [(" vendor/DEEPSEEK-V4-FLASH-0731 ", "0.0000543"),
                              ("deepseek-v4-flash-vision-exp", "0.0000543"), ("deepseek-v3.2", "0.0000378"),
                              ("deepseek-v3.1", "0.00009115"), ("deepseek-v3", "0.0000516")] {
        try save([row("alias", today, nil, model: model)])
        spend = try await load()
        precondition(spend.today.usd == Decimal(string: expected) && spend.today.reference == 1, "Snapshot alias/rate: \(model)")
    }
    for model in ["deepseek-v99-pro", "deepseek-v4-pro-9999", "deepseek-chat", "deepseek-reasoner"] {
        try save([row("unsupported-price", today, nil, model: model)])
        spend = try await load()
        precondition(spend.today.usd == nil && spend.total.unpriced == 1 && spend.total.reference == 0
                     && spend.scannedFiles == 1 && spend.discoveredFiles == 1, "Unknown/ambiguous model is not free or priced by a loose prefix")
    }
    var badTokens = row("bad-tokens", today, 0)
    message = badTokens["message"] as! [String: Any]
    message["usage"] = ["input": 100, "output": true, "cacheRead": 0, "cacheWrite": 0, "cost": ["total": 0]]
    badTokens["message"] = message
    try save([badTokens])
    spend = try await load()
    precondition(spend.today.usd == nil && spend.today.reference == 0 && spend.today.unpriced == 1, "Reference prices cannot make invalid tokens billable")
    try save([row("other-model", today, 99, model: "gpt-5")])
    spend = try await load()
    precondition(spend.today.usd == nil && spend.total.records == 0 && spend.scannedFiles == 1 && spend.discoveredFiles == 1,
                 "Scanning logs with no DeepSeek is distinguishable from no logs; Pi's cross-model footer total is not DeepSeek spend")
    try priceFile(pricing)
    var longWrite = row("long-write", today, nil)
    message = longWrite["message"] as! [String: Any]
    message["usage"] = ["input": 1000, "output": 500, "cacheRead": 200, "cacheWrite": 100, "cacheWrite1h": 50]
    longWrite["message"] = message
    try save([longWrite], tail: "{\"type\":\"message\"")
    spend = try await load()
    precondition(spend.total.usd == Decimal(string: "0.00455") && spend.incomplete, "Pi 1h cache pricing; unfinished tail is not billed")
    try save([longWrite])
    spend = try await load()
    precondition(!spend.incomplete, "Completed rewrite recovers from partial JSONL")
    try save([row("old", thirtyDaysAgo.addingTimeInterval(-1), 1)])
    spend = try await load()
    precondition(spend.today.usd == 0 && spend.last7Days.usd == 0 && spend.last30Days.usd == 0, "Known history outside both rolling windows really is zero")
    try save([row("new", today, 2)])
    spend = try await load(0)
    precondition(spend.total.usd == nil && spend.incomplete && spend.discoveredFiles == 1 && spend.scannedFiles == 0,
                 "An exhausted byte budget reports pending coverage, never changed-file totals")
    spend = try await load()
    precondition(spend.total.usd == 2 && !spend.incomplete, "Deferred files recover on a later scan")
    let oversized = sessions.appendingPathComponent("oversized.jsonl")
    precondition(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(PiLocalSpend.maxFileBytes + 1)); try handle.close()
    spend = try await load()
    precondition(spend.total.usd == 2 && spend.incomplete, "Oversized file is skipped and never presented as full coverage")
    try FileManager.default.removeItem(at: oversized)
    try save([row("new", today, 2)], tail: String(repeating: "x", count: PiLocalSpend.maxLineBytes + 1) + "\n")
    spend = try await load()
    precondition(spend.total.usd == 2 && spend.incomplete, "Oversized/malformed line doesn't discard valid costs or allocate unbounded buffers")
    try save([row("new", today, 2)])
    let fifo = sessions.appendingPathComponent("pipe.jsonl")
    precondition(mkfifo(fifo.path, 0o600) == 0)
    let link = sessions.appendingPathComponent("linked.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    spend = try await load()
    precondition(spend.total.usd == 2 && spend.incomplete && spend.discoveredFiles == 3 && spend.scannedFiles == 1,
                 "FIFO and symlinks remain visible in coverage counts but are not followed or blocked on")
    try FileManager.default.removeItem(at: fifo); try FileManager.default.removeItem(at: link)
    let pending = sessions.appendingPathComponent("newest-incomplete.jsonl")
    try save([], at: pending, tail: "{")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: pending.path)
    let fileBytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).intValue
    let pendingBytes = (try FileManager.default.attributesOfItem(atPath: pending.path)[.size] as! NSNumber).intValue
    let boundedReader = PiLocalSpend()
    let firstPass = try await boundedReader.fetch(home: home, env: [:], now: now, calendar: calendar, byteBudget: max(fileBytes, pendingBytes))
    let firstSummary = try firstPass.result.get().localSpend!
    precondition(firstSummary.total.usd == nil && firstSummary.incomplete, "Newest incomplete file can exhaust this pass's budget")
    let nextPass = try await boundedReader.fetch(home: home, env: [:], now: now, calendar: calendar, byteBudget: max(fileBytes, pendingBytes))
    let nextSummary = try nextPass.result.get().localSpend!
    precondition(nextSummary.total.usd == 2 && nextSummary.incomplete && nextSummary.scannedFiles == 1,
                 "Unchanged incomplete logs must not monopolize every pass and starve readable history")
    try save([row("completed-tail", today, 3)], at: pending)
    let completedPass = try await boundedReader.fetch(home: home, env: [:], now: now, calendar: calendar)
    let completedSummary = try completedPass.result.get().localSpend!
    precondition(completedSummary.total.usd == 5 && !completedSummary.incomplete && completedSummary.scannedFiles == 2,
                 "Changed/completed tails are rescanned and remove the incomplete warning")
    try FileManager.default.removeItem(at: pending)
    let custom = home.appendingPathComponent("custom-sessions")
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    try save([row("custom", today, 7)], at: custom.appendingPathComponent("custom.jsonl"))
    try Data(#"{"sessionDir":"~/custom-sessions"}"#.utf8).write(to: agent.appendingPathComponent("settings.json"))
    spend = try await load()
    precondition(spend.total.usd == 7, "Existing Pi sessionDir setting wins over the default")
    spend = try await load(env: ["PI_CODING_AGENT_SESSION_DIR": sessions.path])
    precondition(spend.total.usd == 2, "Explicit session environment wins over settings without merging other roots")
    let cancelled = Task { try await reader.fetch(home: home, env: [:]) }
    cancelled.cancel()
    do { _ = try await cancelled.value; preconditionFailure("Cancelled scan cannot publish totals") } catch is CancellationError {}
    // A non-readable auth file must not matter: the production DeepSeek path has no authentication step.
    let auth = agent.appendingPathComponent("auth.json")
    precondition(mkfifo(auth.path, 0o600) == 0)
    let livePath = try await UsageTransport.fetch(.deepseek, home: home, env: [:])
    let localReading = try livePath.result.get()
    precondition(localReading.localSpend?.total.usd == 7 && localReading.limits.isEmpty)
    let encoded = String(data: try JSONEncoder().encode(localReading), encoding: .utf8)!
    precondition(!encoded.contains("private-fixture-body") && !encoded.contains("must-not-execute"), "Reading contains no transcript or configured secret")

    let storeDir = root.appendingPathComponent("local-spend-store")
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    var settings = UsageBarSettings(); settings.monitoringEnabled = true; settings.providers = [.deepseek]
    let settingsObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
    let document: [String: Any] = ["version": 1, "settings": settingsObject,
        "retryAfter": ["deepseek": Date().addingTimeInterval(86_400).timeIntervalSinceReferenceDate]]
    try JSONSerialization.data(withJSONObject: document).write(to: storeDir.appendingPathComponent("usage-monitor.json"))
    let counter = LocalReadCount()
    let store = UsageMonitorStore(directory: storeDir, read: { provider in
        await counter.increment()
        return try await UsageTransport.fetch(provider, home: home, env: [:])
    })
    store.start()
    while store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
    let calls = await counter.value
    precondition(calls == 1 && store.readings.first?.localSpend?.total.usd == 7, "Legacy shared-balance 429 cannot block local costs")
    store.updateSettings { $0.monitoringEnabled = false }
    store.refresh(.deepseek)
    try await Task.sleep(for: .milliseconds(20))
    let disabledCalls = await counter.value
    precondition(disabledCalls == calls && store.readings.first?.status == .disabled, "Local scan obeys opt-in and never keeps an active disabled reading")
    await store.stop()
    print("PASS: isolated Pi local spend, cc-switch reference-price goldens, gateway/actual-model rates, pricing diagnostics, fork dedup, Decimal, rolling 7/30-day and DST/today boundaries, mutations, scan progress, limits, cancellation, no authentication and legacy-backoff bypass.")
}
