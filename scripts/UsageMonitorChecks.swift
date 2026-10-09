import AppKit
import Combine
import Foundation
import SQLite3
@testable import UsageMonitor

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
private func rejects(_ operation: () throws -> Void, _ message: String) {
    do { try operation(); preconditionFailure(message) } catch {}
}
private func parsed(_ provider: UsageProviderID, _ json: String) throws -> UsageReading {
    try UsageParsing.parse(Data(json.utf8), provider: provider, now: Date(timeIntervalSince1970: 1_780_000_000))
}

private actor Probe {
    var calls: [UsageProviderID] = []
    var delayed = false
    var rateLimited = false
    var fails = false
    var expired = false
    var identity = "fixture-account-a"
    func configure(delayed: Bool = false, rateLimited: Bool = false, fails: Bool = false, expired: Bool = false, identity: String? = nil) {
        self.delayed = delayed; self.rateLimited = rateLimited; self.fails = fails; self.expired = expired
        if let identity { self.identity = identity }
    }
    func read(_ provider: UsageProviderID) async -> UsageFetchResult {
        let identity = self.identity
        do { return UsageFetchResult(credentialID: identity, result: .success(try await fetch(provider))) }
        catch { return UsageFetchResult(credentialID: identity, result: .failure(error as? UsageFailure ?? .transport)) }
    }
    func fetch(_ provider: UsageProviderID) async throws -> UsageReading {
        calls.append(provider)
        if delayed {
            // Deliberately ignore cancellation, to verify the store rejects late results.
            try? await Task.sleep(for: .milliseconds(150))
        }
        if rateLimited { throw UsageFailure.rateLimited(Date().addingTimeInterval(600)) }
        if fails { throw UsageFailure.transport }
        if expired { throw UsageFailure.credentialExpired }
        return UsageReading(provider: provider, status: .ready,
                            limits: [UsageLimit(id: "fixture", title: "Fixture", usedFraction: 0.8)], updatedAt: Date())
    }
    func count() -> Int { calls.count }
    func providers() -> [UsageProviderID] { calls }
}

/// No socket is opened. Each canned response is selected by the synthetic request's path.
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private final class RequestLog: @unchecked Sendable {
        let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) { lock.withLock { paths.append(path) } }
        func take() -> [String] { lock.withLock { defer { paths = [] }; return paths } }
    }
    private static let log = RequestLog()
    static func paths() -> [String] { log.take() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "www.google.com" {
            check(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil,
                  "Offline Google check is anonymous")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let path = request.url!.path
        Self.log.record(path)
        if path == "/cancel" { return }
        if path.hasPrefix("/backend-api/wham/") {
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-codex", "All Codex GETs keep the same bearer")
            check(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fixture-account", "All Codex GETs keep the same account")
            if path.hasSuffix("rate-limit-reset-credits") {
                check(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1", "Original reset-credit beta header")
            }
            if path.hasSuffix("profiles/me"), request.value(forHTTPHeaderField: "X-Fixture-Cancel") != nil { return }
            let failed = !path.hasSuffix("/usage") && request.value(forHTTPHeaderField: "X-Fixture-Auxiliary-Error") != nil
            let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 401 : 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let name = path.hasSuffix("/usage") ? "usage" : path.hasSuffix("profiles/me") ? "profile" : "resets"
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../Modules/UsageMonitor/Tests/Fixtures")
            client?.urlProtocol(self, didLoad: try! Data(contentsOf: directory.appendingPathComponent("codex-\(name).json")))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status = path == "/rate" ? 429 : (path == "/auth" ? 401 : (path == "/redirect" ? 302 : 200))
        let headers = path == "/oversized" ? ["Content-Length": "1048577"] : ["Retry-After": "300", "Location": "https://other.invalid/secret"]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let json = path == "/malformed" ? "private server error including token must not escape" : #"{"limits":{"monthly":{"usage":0}}}"#
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private struct UsageMonitorChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try parserChecks()
        try copilotChecks()
        try credentialFixtureChecks(root)
        try await piCredentialChecks(root)
        try await piLocalSpendChecks(root)
        try await googleGateChecks(root)
        try await transportChecks()
        try await storeChecks(root)
        try await accountAndReorderChecks(root)
        try await scheduleChecks(root)
        try await independentRefreshChecks(root)
        try await refreshFeedbackChecks(root)
        try await expiredTransportChecks(root)
        try await unavailableCredentialChecks(root)
        try codexActivityChecks(root)
        print("UsageMonitor checks passed: parsers, thresholds, bounded fixtures, transport, opt-in/selection, cancellation, persistence, account isolation, reorder and 429 backoff.")
    }

    static func parserChecks() throws {
        let codex = try parsed(.codex, #"{"rate_limit":{"primary_window":{"used_percent":80,"reset_at":1780003600,"limit_window_seconds":18000},"secondary_window":{"used_percent":100}}}"#)
        check(codex.headline?.usedFraction == 0.8 && codex.limits[1].usedFraction == 1, "Codex thresholds")
        check(codex.headline?.title == "5h limit" && codex.headline?.resetsAt != nil, "Original Codex window metadata")
        let claude = try parsed(.claude, #"{"five_hour":{"utilization":0},"seven_day":{"utilization":102,"resets_at":"2026-10-01T00:00:00.000Z"}}"#)
        check(claude.headline?.usedFraction == 0 && claude.limits[1].usedFraction == 1.02, "Claude zero and overage")
        let modernClaude = try parsed(.claude, #"{"limits":[{"kind":"session","percent":79.9,"resets_at":"2026-10-01T00:00:00Z"}],"five_hour":{"utilization":80}}"#)
        check(modernClaude.limits.count == 1 && modernClaude.headline!.usedFraction! < 0.8, "Claude modern schema wins, no duplicate")
        let cursor = try parsed(.cursor, #"{"individualUsage":{"plan":{"autoPercentUsed":0,"apiPercentUsed":19,"totalPercentUsed":9.5}},"billingCycleEnd":"2026-10-01T00:00:00Z"}"#)
        check(cursor.headline?.usedFraction == 0 && cursor.limits[1].usedFraction == 0.19, "Cursor independent allowance percentages")
        let enterprise = try parsed(.cursor, #"{"individualUsage":{"overall":{"enabled":true,"used":80,"limit":100}}}"#)
        check(enterprise.headline?.usedFraction == 0.8, "Cursor enterprise denominator")
        let copilot = try parsed(.copilot, #"{"quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":20},"chat":{"unlimited":true}},"quota_reset_date":"2026-10-01"}"#)
        check(copilot.headline?.usedFraction == 0.8 && copilot.limits[1].usedFraction == nil, "Copilot real quota/unlimited")
        rejects({ _ = try parsed(.copilot, #"{"quota_snapshots":{"premium_interactions":{"entitlement":100}}}"#) }, "Missing used and remaining cannot invent 0%")
        let ollama = try parsed(.ollama, #"{"limits":{"monthly":{"usage":0.152}},"activity":{"period":{"ending_at":"2026-10-01T00:00:00Z"}}}"#)
        check(ollama.headline?.usedFraction == 0.152 && ollama.headline?.resetsAt == nil, "Ollama native fraction, no fabricated reset")
        let zeroOllama = try parsed(.ollama, #"{"limits":{"monthly":{"usage":0}}}"#)
        check(zeroOllama.headline?.usedFraction == 0, "Ollama legitimate zero")
        rejects({ _ = try parsed(.deepseek, #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.34"}]}"#) }, "Shared DeepSeek balance is no longer a usage reading")
        for (provider, json) in [(UsageProviderID.codex, "{}"), (.ollama, #"{"limits":{"monthly":{"usage":true}}}"#),
                                  (.deepseek, #"{"balance_infos":[{"currency":"USD","total_balance":"2invalid"}]}"#)] {
            rejects({ _ = try parsed(provider, json) }, "Malformed data must fail safely")
        }
        check(UsageParsing.number(Double.infinity) == nil && UsageParsing.number(-1) == nil, "Non-finite/negative use rejected")
        check(UsageLimit(id: "x", title: "x", usedFraction: 1.2).usedFraction == 1.2, "Overage not clamped to 100%")
        rejects({ _ = try UsageParsing.object(Data(repeating: 32, count: 1_048_577)) }, "Response size limit")
        // Untrusted huge durations must not trap during Double -> Int conversion.
        _ = try parsed(.codex, #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":1e100,"reset_after_seconds":1e100}}}"#)
    }

    static func copilotChecks() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Modules/UsageMonitor/Tests/Fixtures/copilot-usage.json")
        let percentage = try UsageParsing.parse(Data(contentsOf: fixture), provider: .copilot)
        check(percentage.displayedHeadline?.id == "premium_interactions"
            && percentage.displayedHeadline?.usedFraction == 0.24, "Copilot percentage-only response reaches the ring")
        check(percentage.limits.count == 3 && percentage.headline?.resetsAt != nil, "Copilot keeps unlimited detail and reset metadata")
        for (quota, expected) in [
            (#"{"entitlement":100,"used":80,"percent_remaining":90,"remaining":30}"#, 0.8),
            (#"{"entitlement":300,"percent_remaining":"76.5","remaining":229}"#, 0.235),
            (#"{"percent_remaining":76}"#, 0.24),
            (#"{"entitlement":null,"percent_remaining":76}"#, 0.24),
            (#"{"entitlement":100,"used":0}"#, 0),
            (#"{"entitlement":100,"remaining":100}"#, 0),
            (#"{"entitlement":100,"remaining":0}"#, 1),
            (#"{"entitlement":100,"used":125}"#, 1.25),
            (#"{"percent_remaining":100}"#, 0),
            (#"{"percent_remaining":0}"#, 1),
            (#"{"percent_remaining":-25}"#, 1.25),
            (#"{"entitlement":100,"remaining":20,"percent_remaining":true}"#, 0.8)
        ] {
            let reading = try parsed(.copilot, "{\"quota_snapshots\":{\"premium_interactions\":\(quota)}}")
            check(abs((reading.displayedHeadline?.usedFraction ?? -1) - expected) < 0.000_001,
                  "Copilot numeric values, explicit used/percentage/count priority and overage")
        }
        for leading in [#"{"unlimited":true,"entitlement":100,"percent_remaining":20}"#,
                        #"{"remaining":12}"#,
                        #"{"entitlement":0,"remaining":0,"percent_remaining":100}"#] {
            let reading = try parsed(.copilot, "{\"quota_snapshots\":{\"premium_interactions\":\(leading),\"chat\":{\"entitlement\":100,\"remaining\":76}}}")
            check(reading.displayedHeadline?.id == "chat" && reading.displayedHeadline?.usedFraction == 0.24,
                  "Unmetered premium quota cannot hide a usable chat ring")
        }
        let completions = try parsed(.copilot, #"{"quota_snapshots":{"chat":{"unlimited":true},"completions":{"percent_remaining":76}}}"#)
        check(completions.displayedHeadline?.id == "completions", "Completions can supply the ring when chat is unlimited")
        for json in [
            #"{"quota_snapshots":{"premium_interactions":{"unlimited":true,"percent_remaining":20}}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100}}}"#,
            #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100,"credits_used":123}}}"#,
            #"{"token_based_billing":true,"quota_snapshots":{}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"remaining":12}}}"#
        ] {
            let reading = try parsed(.copilot, json)
            check(reading.status == .ready && reading.displayedHeadline?.usedFraction == nil && reading.detail != nil,
                  "Successful unmetered/unlimited/token-billed response explains the absent ring, never invents 0%")
        }
        let tokenMetered = try parsed(.copilot, #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":100,"percent_remaining":76}}}"#)
        check(tokenMetered.displayedHeadline?.usedFraction == 0.24 && tokenMetered.detail == nil,
              "Token-based billing flag does not discard genuine metered quota")
        for quota in [#"{}"#, #"{"entitlement":100}"#, #"{"percent_remaining":true}"#,
                      #"{"percent_remaining":"NaN"}"#, #"{"percent_remaining":"inf"}"#,
                      #"{"percent_remaining":101}"#, #"{"entitlement":false,"percent_remaining":76}"#,
                      #"{"entitlement":-1,"percent_remaining":76}"#] {
            rejects({ _ = try parsed(.copilot, "{\"quota_snapshots\":{\"premium_interactions\":\(quota)}}") },
                    "Malformed or incomplete Copilot quota cannot fabricate progress")
        }
        rejects({ _ = try parsed(.copilot, #"{"quota_snapshots":{}}"#) }, "Empty unknown response is not an unlimited plan")
        print("PASS: Copilot percentage/count fixtures, metered headline selection, zero/full/overage and unmetered billing states")
    }

    static func credentialFixtureChecks(_ root: URL) throws {
        let auth = try UsageCredentials.codex(Data(#"{"tokens":{"access_token":"fixture-token","account_id":"fixture-account"}}"#.utf8))
        check(auth.token == "fixture-token" && auth.account == "fixture-account", "Codex auth parser")
        let codexDirectory = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let claims = Data(#"{"https://api.openai.com/auth":{"chatgpt_plan_type":"  plus  "}}"#.utf8).base64EncodedString()
        let authData = Data("{\"tokens\":{\"access_token\":\"fixture-token\",\"account_id\":\"fixture-account\",\"id_token\":\"e30.\(claims).sig\"}}".utf8)
        try authData.write(to: codexDirectory.appendingPathComponent("auth.json"))
        let codexContext = try UsageCredentials.codexRequest(home: root)
        check(codexContext.plan == "plus", "Original ID-token plan fallback, normalized")
        let codexRequest = try UsageCredentials.request(.codex, home: root, env: ["CODEX_HOME": root.appendingPathComponent("different-account").path])
        check(codexRequest == codexContext.request, "Match default CodeNotch profile, not the shell's unrelated account")
        let expiredCodex = "e30." + Data(#"{"exp":1}"#.utf8).base64EncodedString() + ".sig"
        rejects({ _ = try UsageCredentials.codex(Data("{\"tokens\":{\"access_token\":\"\(expiredCodex)\",\"account_id\":\"fixture\"}}".utf8)) }, "Expired Codex session is never refreshed")
        rejects({ _ = try UsageCredentials.codex(Data(#"{"OPENAI_API_KEY":"not-a-codex-session"}"#.utf8)) }, "Codex API keys are not quota sessions")
        rejects({ _ = try UsageCredentials.header("token\r\nInjected: true") }, "Header injection rejected")
        let hosts = UsageCredentials.githubHost("other.example:\n    oauth_token: wrong\ngithub.com:\n    user: fixture-user\n    oauth_token: fixture-token\n    users:\n        other-user:\n            oauth_token: wrong-nested\nother2.example:\n    oauth_token: wrong-again\n")
        check(hosts.account == "fixture-user" && hosts.token == "fixture-token", "gh scoped active account only")
        let ghDir = root.appendingPathComponent(".config/gh")
        try FileManager.default.createDirectory(at: ghDir, withIntermediateDirectories: true)
        let hostURL = ghDir.appendingPathComponent("hosts.yml")
        try Data("github.com:\n    user: fixture-user\n".utf8).write(to: hostURL)
        rejects({ _ = try UsageCredentials.request(.copilot, home: root, env: [:]) }, "gh without a file token does not probe Keychain")
        let fileToken = Data("github.com:\n    user: fixture-user\n    oauth_token: fixture-token\n".utf8)
        try fileToken.write(to: hostURL)
        let ghRequest = try UsageCredentials.request(.copilot, home: root, env: [:])
        check(ghRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Only the existing active-host file token is used")
        let unchangedHosts = try Data(contentsOf: hostURL)
        check(unchangedHosts == fileToken, "gh config is never rewritten or migrated")
        let agentDir = root.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try Data(#"{"authInfo":{"authId":"cli-account"}}"#.utf8).write(to: agentDir.appendingPathComponent("cli-config.json"))
        rejects({ _ = try UsageCredentials.request(.cursor, home: root, env: [:]) }, "Missing editor no longer falls back to cursor-agent/Keychain")
        let dbURL = root.appendingPathComponent("cursor-fixture.vscdb")
        var db: OpaquePointer?
        check(sqlite3_open(dbURL.path, &db) == SQLITE_OK, "create SQLite fixture")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','fixture-token'),('cursorAuth/stripeMembershipAuthId','fixture-account');", nil, nil, nil) == SQLITE_OK, "populate WAL fixture")
        let cookie = try UsageCredentials.cursor(dbURL)
        check(cookie == "WorkosCursorSessionToken=fixture-account::fixture-token", "Cursor reads live WAL read-only")
        let editorURL = root.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: editorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var editorDB: OpaquePointer?
        check(sqlite3_open(editorURL.path, &editorDB) == SQLITE_OK, "Create editor fixture")
        check(sqlite3_exec(editorDB, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','fixture-token'),('cursorAuth/stripeMembershipAuthId','fixture-account');", nil, nil, nil) == SQLITE_OK, "Populate editor fixture")
        sqlite3_close(editorDB)
        let editorRequest = try UsageCredentials.request(.cursor, home: root, env: [:])
        check(editorRequest.value(forHTTPHeaderField: "Cookie") == cookie, "Existing Cursor editor file remains supported")
        let oversized = root.appendingPathComponent("oversized")
        try Data(repeating: 0, count: UsageCredentials.maxBytes + 1).write(to: oversized)
        rejects({ _ = try UsageCredentials.file(oversized) }, "Bounded local file")
        rejects({ _ = try UsageCredentials.file(root) }, "Directories are not credential files")
        let absentDB = root.appendingPathComponent("absent.vscdb")
        rejects({ _ = try UsageCredentials.cursor(absentDB) }, "Missing Cursor sign-in")
        check(!FileManager.default.fileExists(atPath: absentDB.path), "Read-only SQLite never creates missing DB")
        let fifo = root.appendingPathComponent("fifo")
        check(mkfifo(fifo.path, 0o600) == 0, "Create bounded IO fixture")
        rejects({ _ = try UsageCredentials.file(fifo) }, "FIFO must not block credential file read")
        rejects({ _ = try UsageCredentials.cursor(fifo) }, "FIFO must not block SQLite open")
    }

    static func piCredentialChecks(_ root: URL) async throws {
        let home = root.appendingPathComponent("pi-home")
        let directory = home.appendingPathComponent(".config/pi")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authURL = directory.appendingPathComponent("auth.json"), modelsURL = directory.appendingPathComponent("models.json")
        let now = Date(), expiry = now.addingTimeInterval(3600).timeIntervalSince1970 * 1000
        var auth: [String: Any] = [
            "openai-codex": ["type": "oauth", "access": "fixture-codex", "refresh": "never-refresh", "expires": expiry, "accountId": "fixture-account"],
            "anthropic": ["type": "oauth", "access": "sk-ant-oat-fixture", "refresh": "never-refresh", "expires": expiry],
            "github-copilot": ["type": "oauth", "access": "inference-only-do-not-use", "refresh": "gho_fixture", "expires": 1],
            "deepseek": ["type": "api_key", "key": "fixture-deepseek"],
            "ollama": ["type": "api_key", "key": "fixture-ollama"]
        ]
        let models: [String: Any] = ["providers": ["ollama": ["baseUrl": "https://ollama.com/v1"]]]
        func save(_ value: [String: Any], _ url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: url) }
        try save(auth, authURL); try save(models, modelsURL)
        let original = try Data(contentsOf: authURL)
        let selected = try UsagePiCredentials.directory(home: home, env: [:])
        check(selected.path == directory.path, "Finder app finds the existing Pi config directory without shell environment")
        let override = try UsagePiCredentials.directory(home: home, env: ["PI_CODING_AGENT_DIR": "~/different-pi"])
        check(override.path == home.appendingPathComponent("different-pi").path, "Explicit Pi directory wins; no scanning across accounts")
        rejects({ _ = try UsagePiCredentials.directory(home: home, env: ["PI_CODING_AGENT_DIR": "relative/pi"]) }, "Ambiguous custom Pi path cannot fall back to another account")
        let codexDirectory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"different-tool-token","account_id":"different-tool-account"}}"#.utf8).write(to: codexDirectory.appendingPathComponent("auth.json"))
        for (provider, host, token) in [(UsageProviderID.codex, "chatgpt.com", "fixture-codex"), (.claude, "api.anthropic.com", "sk-ant-oat-fixture"), (.copilot, "api.github.com", "gho_fixture"), (.ollama, "ollama.com", "fixture-ollama")] {
            let context = try UsageCredentials.context(provider, home: home, env: [:], now: now)
            check(context.request.url?.host == host && context.request.httpMethod == "GET", "Compatible Pi credential goes only to its fixed official GET endpoint")
            check(context.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" && !context.isExpired, "Read the correct Pi token, including original GitHub OAuth rather than Copilot inference access")
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        _ = FixtureProtocol.paths()
        let result = try await UsageTransport.fetch(.codex, home: home, env: [:], configuration: config, codexSettings: UsageCodexSettings())
        guard case .success(let reading) = result.result else { preconditionFailure("Pi Codex uses the production transport with offline responses") }
        check(reading.status == .ready && FixtureProtocol.paths().count == 3, "Pi Codex drives all three original quota/statistics GETs with the same account")
        let after = try Data(contentsOf: authURL)
        check(after == original, "Pi credentials are never rewritten or refreshed")

        auth["openai-codex"] = ["type": "oauth", "access": "fixture-codex", "expires": 1, "accountId": "fixture-account"]
        try save(auth, authURL)
        let expired = try await UsageTransport.fetch(.codex, home: home, env: [:], configuration: config)
        guard case .failure(.credentialExpired) = expired.result else { preconditionFailure("Pi OAuth milliseconds/expiry respected") }
        check(expired.credentialID != nil && FixtureProtocol.paths().isEmpty, "Expired Pi login makes zero requests and never switches to the other tool's account")
        try original.write(to: authURL)
        for routing: [String: Any] in [
            ["baseUrl": "https://gateway.invalid/v1"], ["baseUrl": "http://ollama.com"],
            ["baseUrl": "https://ollama.com.evil.invalid"], ["baseUrl": "https://user:pass@ollama.com"],
            ["headers": ["Authorization": "gateway-secret"]], ["env": ["OLLAMA_API_KEY": "do-not-resolve"]],
            ["models": [["id": "custom", "baseUrl": "https://gateway.invalid"]]],
            ["modelOverrides": ["custom": ["baseUrl": "https://gateway.invalid"]]]
        ] {
            var routing = routing
            if routing["baseUrl"] == nil { routing["baseUrl"] = "https://ollama.com/v1" }
            try save(["providers": ["ollama": routing]], modelsURL)
            let blocked = try await UsageTransport.fetch(.ollama, home: home, env: [:], configuration: config)
            guard case .failure(.incompatiblePiCredential) = blocked.result else { preconditionFailure("Gateway and routing overrides fail closed") }
            check(blocked.credentialID == nil && FixtureProtocol.paths().isEmpty, "Incompatible Pi configuration cannot leak credentials to any endpoint")
        }
        try save(models, modelsURL)
        for key in ["!touch /tmp/vitapet-must-not-run", "$OLLAMA_API_KEY", "bad\r\nInjected:true"] {
            auth["ollama"] = ["type": "api_key", "key": key]
            try save(auth, authURL)
            rejects({ _ = try UsageCredentials.context(.ollama, home: home, env: [:]) }, "No commands, environment lookup or header injection")
        }
        auth["anthropic"] = ["type": "api_key", "key": "sk-ant-api-not-subscription"]
        auth["github-copilot"] = ["type": "oauth", "access": "inference-only", "refresh": "gho_fixture", "enterpriseUrl": "company.ghe.com", "expires": expiry]
        try save(auth, authURL)
        for provider: UsageProviderID in [.claude, .copilot] {
            rejects({ _ = try UsageCredentials.context(provider, home: home, env: [:]) }, "API key/enterprise login is not a compatible subscription login")
        }
        try save(["providers": ["ollama": ["baseUrl": "http://localhost:11434/v1"]]], modelsURL)
        rejects({ _ = try UsageCredentials.context(.ollama, home: home, env: [:]) }, "Local Ollama auth is not cloud auth")
        // A literal models.json key is already an existing Pi credential, not a new secret store.
        try save([:], authURL)
        try save(["providers": ["ollama": ["baseUrl": "https://ollama.com/v1", "apiKey": "fixture-literal"]]], modelsURL)
        let literal = try UsageCredentials.context(.ollama, home: home, env: [:])
        check(literal.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-literal", "Existing direct-provider literal key supported")
        try save(["openai": ["type": "oauth", "access": "new-responses-token", "expires": expiry], "CF": ["type": "api_key", "key": "gateway-key"]], authURL)
        try save([:], modelsURL)
        let absent = try UsagePiCredentials.context(.codex, home: home, env: [:], now: now)
        check(absent == nil, "New OpenAI Responses OAuth and CF gateway keys cannot masquerade as Codex OAuth")
        // Cursor must bypass even malformed Pi files instead of trying to convert an inference key to a cookie.
        try Data("broken".utf8).write(to: authURL)
        let cursor = try UsagePiCredentials.context(.cursor, home: home, env: [:], now: now)
        check(cursor == nil, "Cursor does not inspect Pi credentials")
        let local = try UsagePiCredentials.context(.deepseek, home: home, env: [:], now: now)
        check(local == nil, "DeepSeek does not inspect even malformed Pi credentials")
        let localResult = try await UsageTransport.fetch(.deepseek, home: home, env: [:], configuration: config)
        guard case .success(let localReading) = localResult.result else { preconditionFailure("DeepSeek needs no credentials") }
        check(localReading.localSpend?.total.usd == nil && localReading.limits.isEmpty && FixtureProtocol.paths().isEmpty,
              "Absent local logs mean unknown spend, no shared-balance HTTP request")
        do {
            _ = try await UsageTransport.fetch(URLRequest(url: URL(string: "https://fixture.invalid/user/balance")!), provider: .deepseek, configuration: config)
            preconditionFailure("DeepSeek HTTP entry point must be closed")
        } catch UsageFailure.localUsageUnavailable {}
        check(FixtureProtocol.paths().isEmpty, "Even an explicit DeepSeek request cannot start networking")
        print("PASS: offline Pi credential compatibility, official-origin guards, milliseconds, account priority, immutable files and zero-request rejection.")
    }

    @MainActor
    static func unavailableCredentialChecks(_ root: URL) async throws {
        let home = root.appendingPathComponent("unavailable-credentials")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let unavailable: [UsageProviderID] = [.claude, .ollama]
        _ = FixtureProtocol.paths()
        // Exercise the production path, not a mocked credential reader. These sources have no supported file path.
        for provider in unavailable {
            let result = try await UsageTransport.fetch(provider, home: home, env: [:], configuration: configuration)
            guard case .failure(.notConnected) = result.result else { preconditionFailure("Keychain-only source stays unavailable") }
            check(result.credentialID == nil, "Unavailable source exposes no credential identity")
        }
        let store = UsageMonitorStore(directory: root.appendingPathComponent("no-keychain-store"), read: { provider in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
            return try await UsageTransport.fetch(provider, home: home, env: [:], configuration: config)
        })
        store.updateSettings { $0.monitoringEnabled = true; $0.providers = unavailable }
        store.start(); await settle(store)
        check(store.readings.allSatisfy { $0.status == .notConnected && $0.limits.isEmpty }, "Startup gracefully disables unavailable sources")
        store.refresh(); await settle(store)
        for provider in unavailable { store.refresh(provider); await settle(store) }
        check(FixtureProtocol.paths().isEmpty, "Startup/manual refresh sends zero requests for Keychain-only sources")
        await store.stop()
        let files = try FileManager.default.contentsOfDirectory(atPath: home.path)
        check(files.isEmpty, "No replacement credential file or migration is created")
    }

    static func transportChecks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://fixture.invalid" + path)!) }
        var identityRequest = request("/ok")
        identityRequest.setValue("Bearer fixture-a", forHTTPHeaderField: "Authorization")
        let firstIdentity = UsageTransport.credentialID(for: identityRequest)
        check(firstIdentity.count == 64 && !firstIdentity.contains("fixture"), "In-memory credential fingerprint is not a token")
        identityRequest.setValue("Bearer fixture-b", forHTTPHeaderField: "Authorization")
        check(firstIdentity != UsageTransport.credentialID(for: identityRequest), "Token/account change invalidates cache identity")
        let tokenIdentity = UsageTransport.credentialID(for: identityRequest)
        identityRequest.setValue("fixture-account-b", forHTTPHeaderField: "ChatGPT-Account-Id")
        check(tokenIdentity != UsageTransport.credentialID(for: identityRequest), "Codex account is included in cache identity")
        let reading = try await UsageTransport.fetch(request("/ok"), provider: .ollama, configuration: configuration)
        check(reading.headline?.usedFraction == 0, "Mock transport success")
        _ = FixtureProtocol.paths()
        var codexRequest = request("/backend-api/wham/usage")
        codexRequest.setValue("Bearer fixture-codex", forHTTPHeaderField: "Authorization")
        codexRequest.setValue("fixture-account", forHTTPHeaderField: "ChatGPT-Account-Id")
        let codex = try await UsageTransport.fetch(codexRequest, provider: .codex, configuration: configuration,
            codexSettings: UsageCodexSettings(showExtraLimits: false, resetTimeFormat: .remaining, showUsagePace: true), fallbackPlan: "pro")
        check(codex.headline?.id == "primary" && codex.limits.count == 2, "Original named headline and extra-limit preference")
        check(codex.plan == "plus" && codex.tokenUsage?.summary?.lifetimeTokens == 123456789, "Official profile statistics and payload plan precedence")
        check(codex.resetCredits?.availableCount == 7 && codex.codexSettings?.showUsagePace == true, "Original unused resets and display preferences")
        check(Set(FixtureProtocol.paths()) == ["/backend-api/wham/usage", "/backend-api/wham/profiles/me", "/backend-api/wham/rate-limit-reset-credits"], "Exactly the three original endpoint paths")
        codexRequest.setValue("true", forHTTPHeaderField: "X-Fixture-Auxiliary-Error")
        let withoutOptional = try await UsageTransport.fetch(codexRequest, provider: .codex, configuration: configuration)
        check(withoutOptional.status == .ready && withoutOptional.tokenUsage == nil && withoutOptional.resetCredits == nil, "Optional endpoint failures cannot fail good quota or invent statistics")
        _ = FixtureProtocol.paths()
        codexRequest.setValue(nil, forHTTPHeaderField: "X-Fixture-Auxiliary-Error")
        codexRequest.setValue("true", forHTTPHeaderField: "X-Fixture-Cancel")
        let cancelledCodexRequest = codexRequest
        let codexCancellation = Task {
            try await UsageTransport.fetch(cancelledCodexRequest, provider: .codex, configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(30))
        codexCancellation.cancel()
        do { _ = try await codexCancellation.value; preconditionFailure("Cancelled optional Codex requests must not publish a reading") }
        catch is CancellationError {}
        _ = FixtureProtocol.paths()
        for path in ["/rate", "/auth", "/redirect", "/oversized", "/malformed"] {
            do {
                _ = try await UsageTransport.fetch(request(path), provider: .ollama, configuration: configuration)
                preconditionFailure("Expected sanitized failure: \(path)")
            } catch let failure as UsageFailure {
                check(!failure.localizedDescription.contains("private server"), "No raw body in error")
                if path == "/rate" {
                    guard case .rateLimited(let date) = failure else { preconditionFailure("429 status") }
                    check(date.timeIntervalSinceNow > 290, "Retry-After seconds")
                }
                if path == "/auth" { guard case .notConnected = failure else { preconditionFailure("401 status") } }
            }
        }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        check(UsageTransport.retryDate("120", now: now) == now.addingTimeInterval(120), "Retry seconds")
        check(UsageTransport.retryDate("invalid", now: now) == now.addingTimeInterval(60), "Backoff fallback")
        let httpDate = "Thu, 01 Oct 2026 00:00:00 GMT"
        check(UsageTransport.retryDate(httpDate, now: now).timeIntervalSince(now) > 60, "HTTP date Retry-After")
        // Exercise the actual delegate; nil declines even a same-origin redirect, so no auth forwarding.
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request("/redirect"))
        let response = HTTPURLResponse(url: request("/redirect").url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        UsageRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                        newRequest: request("/destination")) { redirected in
            check(redirected == nil, "Redirect credentials must not be forwarded")
        }
        session.invalidateAndCancel()
        let cancellation = Task {
            try await UsageTransport.fetch(request("/cancel"), provider: .ollama, configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(20))
        cancellation.cancel()
        do { _ = try await cancellation.value; preconditionFailure("Cancelled network result must not succeed") }
        catch is CancellationError {}
    }

    @MainActor
    static func settle(_ store: UsageMonitorStore) async {
        for _ in 0..<200 {
            if !store.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Refresh failed to settle within test deadline")
    }

    @MainActor
    static func accountAndReorderChecks(_ root: URL) async throws {
        let probe = Probe()
        let directory = root.appendingPathComponent("account-isolation")
        let store = UsageMonitorStore(directory: directory, read: { await probe.read($0) })
        store.updateSettings { $0.monitoringEnabled = true; $0.providers = [.codex, .cursor] }
        store.start(); await settle(store)
        check(store.readings.allSatisfy { $0.status == .ready }, "Account A has valid readings")
        await probe.configure(fails: true)
        store.refresh(); await settle(store)
        check(store.readings.allSatisfy { $0.status == .ready && !$0.limits.isEmpty }, "Original 15-minute grace keeps a recent same-account reading undimmed")
        await probe.configure(fails: true, identity: "fixture-account-b")
        store.refresh(); await settle(store)
        check(store.readings.allSatisfy { $0.status == .failed && $0.limits.isEmpty && $0.updatedAt == nil }, "Account B failure must not show account A quota")
        await probe.configure()
        store.refresh(); await settle(store)
        await probe.configure(delayed: true)
        let beforeReorder = await probe.count()
        store.refresh()
        try await Task.sleep(for: .milliseconds(20))
        store.updateSettings { $0.providers.swapAt(0, 1) }
        check(store.isRefreshing && store.readings.map(\.provider) == [.cursor, .codex], "Reorder retains in-flight work and updates display order")
        await settle(store)
        let afterReorder = await probe.count()
        check(afterReorder == beforeReorder + 2, "Reorder cannot create replacement requests")
        await probe.configure(rateLimited: true)
        store.refresh(); await settle(store)
        check(store.readings.allSatisfy { $0.status == .rateLimited && $0.limits.isEmpty }, "Backoff cannot display an unverified cached account")
        let persisted = try String(contentsOf: directory.appendingPathComponent("usage-monitor.json"), encoding: .utf8)
        check(!persisted.contains("fixture-account") && !persisted.contains("credentialID"), "Identity remains memory-only")
        await store.stop()
        store.start()
        check(store.settings.monitoringEnabled && store.readings.allSatisfy { $0.status == .rateLimited }, "Cancelled quit can restart the same opted-in store")
        await store.stop()
    }

    @MainActor
    static func scheduleChecks(_ root: URL) async throws {
        final class Clock { var now = Date(timeIntervalSince1970: 1_780_000_000) }
        let clock = Clock(), probe = Probe()
        let reset = clock.now.addingTimeInterval(400)
        let store = UsageMonitorStore(directory: root.appendingPathComponent("schedule"), pollingNow: { clock.now }, read: { provider in
            let result = await probe.read(provider)
            return UsageFetchResult(credentialID: result.credentialID, result: result.result.map { reading in
                var reading = reading
                reading.limits[0].resetsAt = reset
                return reading
            })
        })
        store.start(); store.refreshBecauseSomeoneIsLooking(); store.tick(); store.noteCodexWorkState(isBusy: true)
        let before = await probe.count()
        check(before == 0, "Events and activity cannot bypass opt-in")
        store.updateSettings { $0.monitoringEnabled = true; $0.providers = [.codex, .cursor] }
        await settle(store)
        let started = await probe.count()
        clock.now += 299; store.tick(); await settle(store)
        let quiet = await probe.count()
        check(quiet == started, "Idle ticks do not fetch before 300 seconds")
        clock.now += 1; store.tick(); await settle(store)
        let idle = await probe.count()
        check(idle == started + 2, "Idle 300-second refresh")
        clock.now += 14; store.refreshBecauseSomeoneIsLooking(); await settle(store)
        let earlyLook = await probe.count()
        check(earlyLook == idle, "Attention has a shared 15-second cooldown")
        clock.now += 1; store.refreshBecauseSomeoneIsLooking(); await settle(store)
        let look = await probe.count()
        check(look == idle + 2, "Looking refreshes immediately once due")
        store.refreshBecauseSomeoneIsLooking(); await settle(store)
        let repeatedLook = await probe.count()
        check(repeatedLook == look, "Moving between rings cannot multiply requests")
        store.noteCodexWorkState(isBusy: true)
        clock.now += 29; store.tick(); await settle(store)
        let earlyBusy = await probe.count()
        check(earlyBusy == look, "Busy timer waits 30 seconds")
        clock.now += 1; store.tick(); await settle(store)
        let busy = await probe.count()
        check(busy == look + 2, "Busy 30-second refresh")
        clock.now += 1; store.noteCodexWorkState(isBusy: false); await settle(store)
        let ended = await probe.count()
        check(ended == busy + 1, "Work falling edge refreshes Codex only")
        store.noteCodexWorkState(isBusy: true); store.noteCodexWorkState(isBusy: false); await settle(store)
        let flickered = await probe.count()
        check(flickered == ended, "Flickering work state cannot refetch inside 30 seconds")
        clock.now = reset; store.tick(); await settle(store)
        let rollover = await probe.count()
        check(rollover == ended + 2, "Window rollover refreshes even at idle")
        clock.now += 15; store.tick(); await settle(store)
        let pastRollover = await probe.count()
        check(pastRollover == rollover, "A passed reset fires only once")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle(store)
        let wake = await probe.count()
        check(wake == rollover + 2, "Wake requests fresh readings")
        await store.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        store.tick(); store.refreshBecauseSomeoneIsLooking()
        let stopped = await probe.count()
        check(stopped == wake, "Stop removes wake observers and scheduler")
        let staleProbe = Probe()
        let aged = UsageMonitorStore(directory: root.appendingPathComponent("stale-schedule"), pollingNow: { clock.now }, read: { await staleProbe.read($0) })
        aged.updateSettings { $0.monitoringEnabled = true; $0.providers = [.codex] }
        clock.now = Date(); aged.start(); await settle(aged)
        await staleProbe.configure(fails: true)
        clock.now += 899; aged.refresh(); await settle(aged)
        check(aged.readings[0].status == .ready, "Original stale grace lasts fifteen minutes")
        var publications = 0
        let observation = aged.$readings.dropFirst().sink { _ in publications += 1 }
        for _ in 0..<20 { aged.tick() }
        check(publications == 0, "Unchanged stale checks must not invalidate the UI")
        clock.now += 2; aged.tick()
        check(aged.readings[0].status == .stale && publications == 1, "Crossing the stale threshold publishes exactly once")
        aged.tick()
        check(publications == 1, "Already-stale readings must not publish again")
        observation.cancel()
        aged.refresh(); await settle(aged)
        check(aged.readings[0].status == .stale, "Reading dims after fifteen minutes without success")
        await aged.stop()
    }

    @MainActor
    static func independentRefreshChecks(_ root: URL) async throws {
        actor PendingSource {
            var calls: [UsageProviderID] = []
            var held: CheckedContinuation<Void, Never>?
            func read(_ provider: UsageProviderID) async -> UsageFetchResult {
                calls.append(provider)
                if provider == .cursor { await withCheckedContinuation { held = $0 } }
                return UsageFetchResult(credentialID: "fixture", result: .success(UsageReading(provider: provider, status: .ready)))
            }
            func count(_ provider: UsageProviderID) -> Int { calls.filter { $0 == provider }.count }
            func release() { held?.resume(); held = nil }
        }
        let source = PendingSource()
        let store = UsageMonitorStore(directory: root.appendingPathComponent("deadline"), read: { await source.read($0) })
        store.updateSettings { $0.monitoringEnabled = true; $0.providers = [.codex, .cursor] }
        store.start()
        for _ in 0..<100 where store.readings.first?.status != .ready { try await Task.sleep(for: .milliseconds(5)) }
        check(store.readings.first?.status == .ready && store.inFlightForTesting == [.cursor], "Slow source cannot delay another provider's reading")
        store.refresh(.codex)
        for _ in 0..<100 where store.inFlightForTesting.contains(.codex) { try await Task.sleep(for: .milliseconds(5)) }
        let beforeDeadline = await source.count(.codex)
        check(beforeDeadline == 2, "Single-provider event is independent of the all-provider pass")
        store.abandonRefresh()
        check(!store.isRefreshing && store.refreshing.isEmpty && store.inFlightForTesting == [.cursor], "Original deadline frees feedback/pass without dropping blocked work")
        store.refresh()
        for _ in 0..<100 where store.inFlightForTesting.contains(.codex) { try await Task.sleep(for: .milliseconds(5)) }
        let slowReads = await source.count(.cursor), fastReads = await source.count(.codex)
        check(slowReads == 1 && fastReads == 3, "After deadline, healthy sources refetch without stacking stuck reads")
        store.updateSettings { $0.monitoringEnabled = false }
        await source.release()
        await store.stop()
        check(store.readings.allSatisfy { $0.status == .disabled }, "Uncancellable late response cannot re-enable monitoring")
        let probe = Probe()
        let cached = UsageMonitorStore(directory: root.appendingPathComponent("expired-cache"), read: { await probe.read($0) })
        cached.updateSettings { $0.monitoringEnabled = true; $0.providers = [.codex] }
        cached.start(); await settle(cached)
        let last = cached.readings[0].updatedAt
        await probe.configure(expired: true)
        cached.refresh(); await settle(cached)
        check(cached.readings[0].status == .ready && cached.readings[0].updatedAt == last, "Local token expiry ages the verified account, not fabricated sign-out")
        await probe.configure(expired: true, identity: "fixture-other-account")
        cached.refresh(); await settle(cached)
        check(cached.readings[0].limits.isEmpty, "Expired credentials for another account cannot inherit prior quota")
        await cached.stop()
    }

    @MainActor
    static func refreshFeedbackChecks(_ root: URL) async throws {
        let probe = Probe()
        let store = UsageMonitorStore(directory: root.appendingPathComponent("refresh-feedback"), read: { await probe.read($0) })
        store.updateSettings { $0.monitoringEnabled = true; $0.providers = [.codex, .cursor] }
        store.start(); await settle(store)
        check(store.refreshing.isEmpty, "Startup feedback clears on completion")
        store.refreshBecauseSomeoneIsLooking()
        let before = await probe.count()
        store.refresh(.codex)
        check(store.refreshing == [.codex], "An explicit click is not swallowed by the 15s attention gate and only marks its own ring")
        try await Task.sleep(for: .milliseconds(100))
        check(store.refreshing == [.codex], "Fast result keeps the original 380ms press feedback")
        store.refresh(.codex); store.refresh(.codex)
        store.refresh(.cursor)
        check(store.refreshing == [.codex, .cursor], "Another source can refresh independently during feedback")
        await settle(store)
        let after = await probe.count()
        check(after == before + 2 && store.refreshing.isEmpty, "Repeated clicks deduplicate until feedback ends; all indicators eventually clear")
        await probe.configure(fails: true)
        store.refresh(.codex); await settle(store)
        check(store.refreshing.isEmpty, "Failed request cannot leave a spinner")
        await probe.configure(rateLimited: true)
        store.refresh(.codex); await settle(store)
        let limited = await probe.count()
        store.refresh(.codex)
        let blocked = await probe.count()
        check(store.refreshing.isEmpty && blocked == limited, "Backoff refuses both another request and fake refresh feedback")
        await probe.configure(delayed: true)
        store.refresh(.cursor)
        store.updateSettings { $0.monitoringEnabled = false }
        check(store.refreshing.isEmpty, "Disabling immediately clears feedback while cancelled work unwinds")
        await store.stop()
        check(store.refreshing.isEmpty && !store.isRefreshing, "Stopping never leaves feedback behind")
        print("PASS: single-source feedback, explicit clicks inside attention cooldown, 380ms hold, deduplication, failures, backoff and cancellation.")
    }

    static func expiredTransportChecks(_ root: URL) async throws {
        let home = root.appendingPathComponent("expired-home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let token = "e30." + Data(#"{"exp":1}"#.utf8).base64EncodedString() + ".sig"
        let url = home.appendingPathComponent(".codex/auth.json")
        let original = Data("{\"tokens\":{\"access_token\":\"\(token)\",\"account_id\":\"fixture\"}}".utf8)
        try original.write(to: url)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        _ = FixtureProtocol.paths()
        let result = try await UsageTransport.fetch(.codex, home: home, env: [:], configuration: config)
        guard case .failure(.credentialExpired) = result.result else { preconditionFailure("Original expired-token outcome") }
        check(result.credentialID != nil && FixtureProtocol.paths().isEmpty, "Expired token has memory-only identity but makes zero requests")
        let unchanged = try Data(contentsOf: url)
        check(unchanged == original, "Borrowed auth is never refreshed or rewritten")
    }

    @MainActor
    static func codexActivityChecks(_ root: URL) throws {
        let now = Date()
        let rollout = root.appendingPathComponent("lifecycle.jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8).write(to: rollout)
        check(CodexRolloutActivity.state(from: rollout) == .busy, "Original task_started activity")
        let dbURL = root.appendingPathComponent("activity.sqlite")
        var db: OpaquePointer?
        check(sqlite3_open(dbURL.path, &db) == SQLITE_OK, "Activity fixture database")
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE threads(id TEXT, rollout_path TEXT, source TEXT, archived INTEGER, updated_at_ms INTEGER, preview TEXT); INSERT INTO threads VALUES('fixture','\(rollout.path)','vscode',0,1,'not needed for quota scheduling');"
        check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Activity fixture row")
        let absent = root.appendingPathComponent("absent-desktop.sqlite")
        let cache = CodexStoreCache()
        let threads = cache.recentThreads(in: dbURL)
        check(threads.count == 1 && threads[0].preview == nil, "No prompt/title content fetched for quota scheduling")
        let busy = CodexActivityMonitor.read(stateStore: dbURL, desktopStore: absent, staleAfter: 8, now: now, cache: cache, openRollouts: [])
        check(busy.count == 1 && busy[0].state == .busy, "Upstream activity reader drives busy cadence")
        let quiet = CodexActivityMonitor.read(stateStore: dbURL, desktopStore: absent, staleAfter: 8, now: now.addingTimeInterval(10), cache: cache, openRollouts: [])
        check(quiet.isEmpty, "Original eight-second freshness heuristic")
        let stillOpen = CodexActivityMonitor.read(stateStore: dbURL, desktopStore: absent, staleAfter: 8, now: now.addingTimeInterval(10), cache: cache, openRollouts: [rollout.path])
        check(stillOpen.first?.state == .busy, "Quiet but open in-flight rollout remains busy")
        let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        try Data((completed + "\n").utf8).write(to: rollout)
        let finished = CodexActivityMonitor.read(stateStore: dbURL, desktopStore: absent, staleAfter: 8, now: now, cache: CodexStoreCache(), openRollouts: [])
        check(finished.first?.state == .success, "Original task_complete falling edge")
        let fifo = root.appendingPathComponent("activity-fifo")
        check(mkfifo(fifo.path, 0o600) == 0, "Activity FIFO fixture")
        check(CodexRolloutActivity.state(from: fifo) == nil && SQLiteStore.open(fifo) == nil, "Activity reads cannot block on a FIFO")
        check(!FileManager.default.fileExists(atPath: absent.path), "Read-only activity never creates a missing DB")
    }

    @MainActor
    static func storeChecks(_ root: URL) async throws {
        let probe = Probe()
        let directory = root.appendingPathComponent("store")
        let store = UsageMonitorStore(directory: directory, fetch: { try await probe.fetch($0) })
        check(store.settings.monitoringEnabled == false, "Monitoring defaults off")
        store.start(); store.refresh()
        try await Task.sleep(for: .milliseconds(20))
        let before = await probe.count()
        check(before == 0, "No reads before explicit opt-in")
        store.updateSettings { $0.providers = [.codex, .codex]; $0.monitoringEnabled = true; $0.scale = .infinity; $0.opacity = -4; $0.horizontalPosition = 5; $0.screenID = "invalid" }
        check(store.settings.providers == [.codex] && store.settings.scale == 1 && store.settings.opacity == 0.3 && store.settings.horizontalPosition == 1 && store.settings.screenID == nil, "Normalize untrusted settings")
        store.refresh(.claude); store.refresh()
        await settle(store)
        let selected = await probe.providers()
        check(selected == [.codex] && store.readings.first?.headline?.usedFraction == 0.8, "Only selected provider; overlapping refresh rejected")
        for style in UsageBarSurfaceStyle.allCases {
            store.updateSettings { $0.surfaceStyle = style }
            let reloaded = UsageMonitorStore(directory: directory, fetch: { try await probe.fetch($0) })
            check(reloaded.settings == store.settings, "Atomic surface-style persistence round-trip")
        }
        let settingsData = try Data(contentsOf: directory.appendingPathComponent("usage-monitor.json"))
        var legacyDocument = try JSONSerialization.jsonObject(with: settingsData) as! [String: Any]
        var legacySettings = legacyDocument["settings"] as! [String: Any]
        legacySettings.removeValue(forKey: "surfaceStyle")
        legacySettings["refreshInterval"] = 60 // Obsolete custom interval must not override upstream scheduling.
        legacyDocument["settings"] = legacySettings
        let legacyDirectory = root.appendingPathComponent("legacy-surface")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyFile = legacyDirectory.appendingPathComponent("usage-monitor.json")
        try JSONSerialization.data(withJSONObject: legacyDocument).write(to: legacyFile)
        let legacy = UsageMonitorStore(directory: legacyDirectory, fetch: { try await probe.fetch($0) })
        var expected = store.settings
        expected.surfaceStyle = .glass
        check(legacy.settings == expected && legacy.settingsError == nil, "Existing settings keep opt-in, sources and placement without the new surface key")
        legacySettings["surfaceStyle"] = "future-style"
        legacyDocument["settings"] = legacySettings
        let futureStyleData = try JSONSerialization.data(withJSONObject: legacyDocument)
        try futureStyleData.write(to: legacyFile)
        let unknownStyle = UsageMonitorStore(directory: legacyDirectory, fetch: { try await probe.fetch($0) })
        unknownStyle.updateSettings { $0.monitoringEnabled = true }
        let preservedStyleData = try Data(contentsOf: legacyFile)
        check(unknownStyle.settingsError != nil && !unknownStyle.settings.monitoringEnabled && preservedStyleData == futureStyleData, "Unknown surface styles remain preserved, not reset or overwritten")
        let timestamp = store.readings.first?.updatedAt
        await probe.configure(fails: true)
        store.refresh(); await settle(store)
        check(store.readings.first?.status == .ready && store.readings.first?.updatedAt == timestamp && store.readings.first?.headline?.usedFraction == 0.8, "Recent failure preserves dated data during upstream stale grace")
        await probe.configure(delayed: true)
        store.refresh()
        try await Task.sleep(for: .milliseconds(10))
        store.updateSettings { $0.monitoringEnabled = false }
        try await Task.sleep(for: .milliseconds(180))
        check(store.readings.allSatisfy { $0.status == .disabled && $0.limits.isEmpty }, "Late response cannot re-enable readings")
        await store.stop()

        await probe.configure(rateLimited: true)
        let limited = UsageMonitorStore(directory: root.appendingPathComponent("limited"), fetch: { try await probe.fetch($0) })
        limited.updateSettings { $0.monitoringEnabled = true; $0.providers = [.copilot] }
        limited.start(); await settle(limited)
        check(limited.readings.first?.status == .rateLimited, "429 is supported data state")
        let count = await probe.count()
        limited.refresh(); limited.refresh(.copilot)
        try await Task.sleep(for: .milliseconds(20))
        let afterManual = await probe.count()
        check(count == afterManual, "Manual refresh honors backoff")
        await limited.stop()
        let restarted = UsageMonitorStore(directory: root.appendingPathComponent("limited"), fetch: { try await probe.fetch($0) })
        restarted.start(); restarted.refresh()
        try await Task.sleep(for: .milliseconds(20))
        let afterRestart = await probe.count()
        check(count == afterRestart && restarted.readings.first?.status == .rateLimited, "Backoff survives restart")
        restarted.updateSettings { $0.providers = [] }
        check(restarted.readings.isEmpty && !restarted.isRefreshing, "Empty provider list is safe")
        await restarted.stop()

        let corruptDirectory = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptURL = corruptDirectory.appendingPathComponent("usage-monitor.json")
        let corrupt = Data("not-json-original".utf8)
        try corrupt.write(to: corruptURL)
        let broken = UsageMonitorStore(directory: corruptDirectory, fetch: { try await probe.fetch($0) })
        broken.updateSettings { $0.monitoringEnabled = true }
        let preserved = try Data(contentsOf: corruptURL)
        check(broken.settingsError != nil && !broken.settings.monitoringEnabled && preserved == corrupt, "Corrupt settings preserved, monitoring remains off")
        let fileNotDirectory = root.appendingPathComponent("not-directory")
        try Data("fixture".utf8).write(to: fileNotDirectory)
        let unwritable = UsageMonitorStore(directory: fileNotDirectory, fetch: { try await probe.fetch($0) })
        let old = unwritable.settings
        unwritable.updateSettings { $0.monitoringEnabled = true }
        check(unwritable.settings == old && unwritable.settingsError != nil, "Failed writes never publish candidate settings")
    }
}
