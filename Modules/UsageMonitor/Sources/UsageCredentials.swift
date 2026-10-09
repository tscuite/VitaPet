import Foundation
import SQLite3
import Darwin

/// Existing file-based sign-ins only. No Keychain access (including presence checks or app-owned items),
/// CLI, shell, browser, credential migration, token refresh, or sign-in is launched.
enum UsageCredentials {
    typealias Context = (request: URLRequest, plan: String?, isExpired: Bool)
    static let maxBytes = 262_144

    /// Pi first for compatible official credentials; only an absent Pi entry may use the existing tool file.
    static func context(_ provider: UsageProviderID, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        env: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) throws -> Context {
        if let pi = try UsagePiCredentials.context(provider, home: home, env: env, now: now) { return pi }
        if provider == .codex { return try codexRequest(home: home, now: now) }
        return (try request(provider, home: home, env: env), nil, false)
    }

    static func get(_ endpoint: String, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    /// Only a bounded regular file can be read; FIFOs/devices must never block the monitor.
    static func file(_ url: URL, limit: Int = maxBytes) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw UsageFailure.notConnected }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw UsageFailure.invalidResponse }
        var data = Data(count: limit + 1)
        let size = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, limit + 1) }
        guard size >= 0, size <= limit else { throw UsageFailure.invalidResponse }
        data.count = size
        return data
    }
    static func header(_ value: String?) throws -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 16_384,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 }) else { throw UsageFailure.notConnected }
        return value
    }
    static func codex(_ data: Data, now: Date = Date(), checkExpiry: Bool = true) throws -> (token: String, account: String) {
        let root = try UsageParsing.object(data)
        guard let tokens = root["tokens"] as? [String: Any] else { throw UsageFailure.notConnected }
        let token = try header(tokens["access_token"] as? String)
        if checkExpiry, let expiry = UsageParsing.number(jwtClaims(token)?["exp"]), expiry <= now.timeIntervalSince1970 {
            throw UsageFailure.credentialExpired
        }
        return (token, try header(tokens["account_id"] as? String))
    }

    /// CodeNotch's default CodexProfile is ~/.codex, even when a shell has CODEX_HOME.
    /// Read the token, account and fallback plan from one file observation, never mix accounts.
    static func codexRequest(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) throws -> Context {
        try Task.checkCancellation()
        let data = try file(home.appendingPathComponent(".codex/auth.json"))
        let credential = try codex(data, checkExpiry: false)
        let isExpired = UsageParsing.number(jwtClaims(credential.token)?["exp"]).map { $0 <= now.timeIntervalSince1970 } ?? false
        let tokens = try UsageParsing.object(data)["tokens"] as? [String: Any]
        let claims = (tokens?["id_token"] as? String).flatMap(jwtClaims)
        let plan = (claims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        let request = get("https://chatgpt.com/backend-api/wham/usage", headers: [
            "Authorization": "Bearer \(credential.token)", "ChatGPT-Account-Id": credential.account
        ])
        try Task.checkCancellation()
        return (request, plan?.nonEmptyPlan, isExpired)
    }
    static func cursor(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw UsageFailure.notConnected
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw UsageFailure.notConnected
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(maxBytes))
        // An indexed two-key lookup should be far below this instruction budget.
        sqlite3_progress_handler(db, 100_000, { _ in 1 }, nil)
        var statement: OpaquePointer?
        let sql = "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/stripeMembershipAuthId') LIMIT 2"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageFailure.notConnected }
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1),
                  sqlite3_column_bytes(statement, 1) <= 16_384 else { throw UsageFailure.notConnected }
            values[String(cString: key)] = String(cString: value)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw UsageFailure.notConnected }
        let token = try header(values["cursorAuth/accessToken"])
        let account = values["cursorAuth/stripeMembershipAuthId"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (jwtClaims(token)?["sub"] as? String)
        return "WorkosCursorSessionToken=\(try header(account))::\(token)"
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? UsageParsing.object(data)
    }

    /// Minimal gh hosts.yml subset, deliberately restricted to github.com; no general YAML interpreter.
    static func githubHost(_ text: String) -> (account: String?, token: String?) {
        var inHost = false
        var account: String?, token: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inHost = line.trimmingCharacters(in: .whitespacesAndNewlines) == "github.com:"
                continue
            }
            guard inHost else { continue }
            // gh's active host fields are at four spaces; nested users tokens must not replace them.
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent == 4 || indent == 2 else { continue }
            let field = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard field.count == 2 else { continue }
            let value = field[1].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if field[0] == "user" { account = value }
            if field[0] == "oauth_token" { token = value }
        }
        return (account, token)
    }

    static func request(_ provider: UsageProviderID,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        env: [String: String] = ProcessInfo.processInfo.environment) throws -> URLRequest {
        try Task.checkCancellation()
        func directory(_ variable: String, fallback: URL) -> URL {
            guard let path = env[variable], path.hasPrefix("/"), path.count < 4096 else { return fallback }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        var headers: [String: String] = [:]
        let endpoint: String
        switch provider {
        case .codex:
            let context = try codexRequest(home: home)
            guard !context.isExpired else { throw UsageFailure.credentialExpired }
            return context.request
        case .claude, .ollama, .deepseek:
            // Their existing sources required Keychain. Do not probe or replace them with a new secret source.
            throw UsageFailure.notConnected
        case .cursor:
            endpoint = "https://cursor.com/api/usage-summary"
            let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            headers = ["Cookie": try cursor(path)]
        case .copilot:
            endpoint = "https://api.github.com/copilot_internal/user"
            let config = directory("GH_CONFIG_DIR", fallback: directory("XDG_CONFIG_HOME", fallback: home.appendingPathComponent(".config")).appendingPathComponent("gh"))
            let text = (try? file(config.appendingPathComponent("hosts.yml"))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let host = githubHost(text)
            // Only gh's already-supported active-host file token; never invoke gh or a keyring helper.
            headers = ["Authorization": "Bearer \(try header(host.token))", "X-GitHub-Api-Version": "2022-11-28"]
        }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        headers["Accept"] = "application/json"; headers["User-Agent"] = "VitaPet-UsageMonitor"
        headers["Cache-Control"] = "no-store"
        request.allHTTPHeaderFields = headers
        return request
    }
}
