import Foundation
import Darwin

/// Read-only subset of Pi's documented auth.json. Never load Pi/extension code, resolve environment
/// secrets, execute !commands, refresh OAuth, or copy credentials into VitaPet's settings.
enum UsagePiCredentials {
    static func directory(home: URL, env: [String: String]) throws -> URL {
        if let path = env["PI_CODING_AGENT_DIR"], !path.isEmpty {
            let expanded = path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
            guard expanded.hasPrefix("/"), expanded.utf8.count < 4096 else { throw UsageFailure.incompatiblePiCredential }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let standard = home.appendingPathComponent(".pi/agent")
        // Finder-launched apps don't inherit the shell override used by this installation of Pi.
        if FileManager.default.fileExists(atPath: standard.path) { return standard }
        let configured = home.appendingPathComponent(".config/pi")
        return FileManager.default.fileExists(atPath: configured.path) ? configured : standard
    }

    static func context(_ provider: UsageProviderID, home: URL, env: [String: String], now: Date) throws -> UsageCredentials.Context? {
        // DeepSeek is local accounting; Cursor needs its editor cookie. Neither opens Pi credentials.
        guard provider != .cursor, provider != .deepseek else { return nil }
        try Task.checkCancellation()
        let directory = try directory(home: home, env: env)
        let auth = try objectIfPresent(directory.appendingPathComponent("auth.json"))
        let id: String
        let hosts: Set<String>
        switch provider {
        case .codex: id = "openai-codex"; hosts = ["chatgpt.com"]
        case .claude: id = "anthropic"; hosts = ["api.anthropic.com"]
        case .copilot: id = "github-copilot"; hosts = ["api.githubcopilot.com", "api.individual.githubcopilot.com", "api.business.githubcopilot.com", "api.enterprise.githubcopilot.com"]
        case .ollama: id = "ollama"; hosts = ["ollama.com"]
        case .cursor, .deepseek: return nil
        }
        let models = try objectIfPresent(directory.appendingPathComponent("models.json"))
        guard models["providers"] == nil || models["providers"] is [String: Any] else { throw UsageFailure.incompatiblePiCredential }
        let providers = models["providers"] as? [String: Any] ?? [:]
        guard providers[id] == nil || providers[id] is [String: Any],
              auth[id] == nil || auth[id] is [String: Any] else { throw UsageFailure.incompatiblePiCredential }
        let config = providers[id] as? [String: Any] ?? [:]
        let credential = auth[id] as? [String: Any]
        let isAPI = provider == .ollama
        guard credential != nil || (isAPI && config["apiKey"] != nil) else { return nil }
        try checkRouting(config, hosts: hosts)
        // An extension/provider-scoped environment can change routing or authentication. Do not evaluate it.
        if let environment = credential?["env"], (environment as? [String: Any])?.isEmpty != true {
            throw UsageFailure.incompatiblePiCredential
        }
        var headers = ["User-Agent": "VitaPet-UsageMonitor"]
        let endpoint: String
        let token: String
        var plan: String?
        var expired = false
        switch provider {
        case .codex, .claude:
            guard credential?["type"] as? String == "oauth",
                  let expiry = UsageParsing.number(credential?["expires"]) else { throw UsageFailure.incompatiblePiCredential }
            token = try literal(credential?["access"])
            expired = expiry / 1000 <= now.timeIntervalSince1970 // Pi stores milliseconds, not JWT seconds.
            if provider == .codex {
                let claims = UsageCredentials.jwtClaims(token)
                let accountClaims = claims?["https://api.openai.com/auth"] as? [String: Any]
                let claimAccount = accountClaims?["chatgpt_account_id"] as? String
                let storedAccount = credential?["accountId"] as? String
                guard storedAccount == nil || claimAccount == nil || storedAccount == claimAccount else {
                    throw UsageFailure.incompatiblePiCredential
                }
                headers["ChatGPT-Account-Id"] = try UsageCredentials.header(storedAccount ?? claimAccount)
                plan = (accountClaims?["chatgpt_plan_type"] as? String)?.nonEmptyPlan
                if let jwtExpiry = UsageParsing.number(claims?["exp"]) { expired = expired || jwtExpiry <= now.timeIntervalSince1970 }
                endpoint = "https://chatgpt.com/backend-api/wham/usage"
            } else {
                // A Claude API key is not a Pro/Max subscription credential.
                guard token.hasPrefix("sk-ant-oat") else { throw UsageFailure.incompatiblePiCredential }
                headers["anthropic-beta"] = "oauth-2025-04-20"
                headers["anthropic-version"] = "2023-06-01"
                endpoint = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1"
            }
        case .copilot:
            // Pi's `refresh` holds the original GitHub OAuth token, not a refresh grant. The short-lived
            // `access` is a Copilot inference token and must NEVER be sent to GitHub's quota endpoint.
            if let enterprise = credential?["enterpriseUrl"], (enterprise as? String)?.isEmpty != true {
                throw UsageFailure.incompatiblePiCredential
            }
            guard credential?["type"] as? String == "oauth" else { throw UsageFailure.incompatiblePiCredential }
            token = try literal(credential?["refresh"])
            guard token.hasPrefix("gho_") || token.hasPrefix("ghu_") else { throw UsageFailure.incompatiblePiCredential }
            headers["X-GitHub-Api-Version"] = "2022-11-28"
            endpoint = "https://api.github.com/copilot_internal/user"
        case .ollama:
            if let credential, credential["type"] as? String != "api_key" { throw UsageFailure.incompatiblePiCredential }
            // `ollama` is normally local/custom in Pi. Require an explicit official cloud origin.
            guard config["baseUrl"] != nil else { throw UsageFailure.incompatiblePiCredential }
            token = try literal(credential == nil ? config["apiKey"] : credential?["key"])
            endpoint = "https://ollama.com/api/usage"
        case .cursor, .deepseek: return nil
        }
        headers["Authorization"] = "Bearer \(token)"
        try Task.checkCancellation()
        return (UsageCredentials.get(endpoint, headers: headers), plan, expired)
    }

    private static func literal(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.hasPrefix("!"), !value.contains("$") else {
            throw UsageFailure.incompatiblePiCredential
        }
        return try UsageCredentials.header(value)
    }

    private static func objectIfPresent(_ path: URL) throws -> [String: Any] {
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw UsageFailure.incompatiblePiCredential }
            return [:]
        }
        return try UsageParsing.object(UsageCredentials.file(path))
    }

    /// Fixed allowlisted endpoints only. Provider/model overrides cannot turn a gateway key into a
    /// vendor credential; extra headers and alternate origins fail closed rather than leak that key.
    private static func checkRouting(_ config: [String: Any], hosts: Set<String>, depth: Int = 0) throws {
        guard depth < 16 else { throw UsageFailure.incompatiblePiCredential }
        if let raw = config["baseUrl"] {
            guard let raw = raw as? String, let url = URL(string: raw), url.scheme == "https",
                  let host = url.host?.lowercased(), hosts.contains(host), url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else {
                throw UsageFailure.incompatiblePiCredential
            }
        }
        if let headers = config["headers"], (headers as? [String: Any])?.isEmpty != true {
            throw UsageFailure.incompatiblePiCredential
        }
        if let environment = config["env"], (environment as? [String: Any])?.isEmpty != true {
            throw UsageFailure.incompatiblePiCredential
        }
        if let models = config["models"] {
            guard let models = models as? [[String: Any]] else { throw UsageFailure.incompatiblePiCredential }
            for model in models { try checkRouting(model, hosts: hosts, depth: depth + 1) }
        }
        if let overrides = config["modelOverrides"] {
            guard let overrides = overrides as? [String: [String: Any]] else { throw UsageFailure.incompatiblePiCredential }
            for model in overrides.values { try checkRouting(model, hosts: hosts, depth: depth + 1) }
        }
    }
}
