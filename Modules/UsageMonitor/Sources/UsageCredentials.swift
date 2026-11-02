import Foundation
import CryptoKit
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
        // Ollama: the direct key (env or ollama's own file) outranks Pi's copy.
        if provider == .ollama, let key = ollamaKey(home: home, env: env) {
            return (get("https://ollama.com/api/usage", headers: ["Authorization": "Bearer \(try header(key))"]), nil, false)
        }
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
        case .claude, .deepseek:
            // Their existing sources required Keychain. Do not probe or replace them with a new secret source.
            throw UsageFailure.notConnected
        case .ollama:
            endpoint = "https://ollama.com/api/usage"
            headers = ["Authorization": "Bearer \(try header(ollamaKey(home: home, env: env)))"]
        case .glm:
            let credential = try glmCredential(home: home, env: env)
            endpoint = credential.baseURL.absoluteString + "/api/monitor/usage/quota/limit"
            // The monitor takes the key raw — no Bearer scheme.
            headers = ["Authorization": try header(credential.token)]
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

    // MARK: - GLM Coding Plan credentials
    // Adapted from CodeNotch GLMCredentials/ZCodeCredentialCipher (MIT); see THIRD_PARTY_NOTICES.md.

    struct GLMCredential {
        let token: String
        /// The console this key belongs to (api.z.ai or open.bigmodel.cn) — it decides the monitor host.
        let baseURL: URL
        /// The tool the key was found under, for diagnostics.
        let source: String
    }

    /// The Z.ai key behind a GLM Coding Plan, borrowed from whichever coding tool already holds it.
    /// No key is ever stored, entered or refreshed here; each source is a plain existing file.
    static func glmCredential(home: URL, env: [String: String]) throws -> GLMCredential {
        try Task.checkCancellation()
        func json(_ path: String) -> [String: Any]? {
            guard let data = try? file(home.appendingPathComponent(path)),
                  let root = try? UsageParsing.object(data) as [String: Any] else { return nil }
            return root
        }
        // Order mirrors upstream: Claude Code, ZCode config, ZCode credentials, OpenCode.
        if let c = json(".claude/settings.json").flatMap(glmClaudeCode) { return c }
        if let c = json(".zcode/v2/config.json").flatMap(glmZCodePlanKey) { return c }
        if let root = json(".zcode/v2/credentials.json"),
           let c = glmZCode(root, secret: ZCodeCredentialCipher.defaultSecret(env: env, home: home)) { return c }
        if let c = json(".local/share/opencode/auth.json").flatMap(glmOpenCode) { return c }
        throw UsageFailure.notConnected
    }

    /// `~/.claude/settings.json` → env.ANTHROPIC_AUTH_TOKEN/API_KEY plus a Z.ai ANTHROPIC_BASE_URL.
    /// The base URL is what makes this a GLM key: a token aimed at api.anthropic.com is not ours to claim.
    static func glmClaudeCode(_ root: [String: Any]) -> GLMCredential? {
        guard let env = root["env"] as? [String: Any],
              let token = glmString(env["ANTHROPIC_AUTH_TOKEN"]) ?? glmString(env["ANTHROPIC_API_KEY"]),
              let base = glmString(env["ANTHROPIC_BASE_URL"]),
              let host = URL(string: base)?.host, glmIsZaiHost(host) else { return nil }
        return GLMCredential(token: token, baseURL: glmConsoleBase(from: host), source: "Claude Code")
    }

    /// `~/.zcode/v2/config.json` → an enabled builtin:*-coding-plan/start-plan provider whose key was pasted in.
    static func glmZCodePlanKey(_ root: [String: Any]) -> GLMCredential? {
        guard let providers = root["provider"] as? [String: Any] else { return nil }
        for (id, value) in providers.sorted(by: { $0.key < $1.key }) {
            guard id.contains("coding-plan") || id.contains("start-plan"),
                  let provider = value as? [String: Any],
                  let options = provider["options"] as? [String: Any],
                  let key = glmString(options["apiKey"]) else { continue }
            // Explicitly disabled entries are not keys being used.
            if let enabled = provider["enabled"] as? Bool, !enabled { continue }
            let console = glmString(options["baseURL"]).flatMap { URL(string: $0)?.host }.map(glmConsoleBase(from:))
                ?? URL(string: "https://api.z.ai")!
            return GLMCredential(token: key, baseURL: console, source: "ZCode")
        }
        return nil
    }

    /// `~/.zcode/v2/credentials.json` → the per-account plan key, or the sign-in token.
    /// Every value may be encrypted at rest; a value that does not decrypt is skipped, not guessed at.
    static func glmZCode(_ root: [String: Any], secret: String) -> GLMCredential? {
        func read(_ value: Any?) -> String? {
            guard let raw = glmString(value), let plain = ZCodeCredentialCipher.decrypt(raw, secret: secret) else { return nil }
            return plain.isEmpty ? nil : plain
        }
        for key in root.keys.filter(glmIsAccountAPIKey).sorted() {
            if let token = read(root[key]) {
                return GLMCredential(token: token,
                                     baseURL: key.lowercased().contains("bigmodel")
                                        ? URL(string: "https://open.bigmodel.cn")!
                                        : URL(string: "https://api.z.ai")!,
                                     source: "ZCode")
            }
        }
        if let token = read(root["oauth:zai:access_token"]) {
            return GLMCredential(token: token, baseURL: URL(string: "https://api.z.ai")!, source: "ZCode")
        }
        if let token = read(root["oauth:bigmodel:access_token"]) {
            return GLMCredential(token: token, baseURL: URL(string: "https://open.bigmodel.cn")!, source: "ZCode")
        }
        return nil
    }

    /// ZCode files the plan key per account as `account-provider:…:api-key`.
    static func glmIsAccountAPIKey(_ key: String) -> Bool {
        key.hasPrefix("account-provider:") && key.hasSuffix(":api-key")
            && key.count > "account-provider:".count + ":api-key".count
    }

    /// `~/.local/share/opencode/auth.json`, keyed under OpenCode's own provider names, most specific first.
    static func glmOpenCode(_ root: [String: Any]) -> GLMCredential? {
        for id in ["zai-coding-plan", "zai", "z-ai", "z.ai", "glm", "zhipu", "zhipuai"] {
            guard let entry = root[id] else { continue }
            // The entry is either the key itself or an object carrying it — both shapes have shipped.
            if let token = glmString(entry) {
                return GLMCredential(token: token, baseURL: glmConsole(forProviderID: id), source: "OpenCode")
            }
            if let object = entry as? [String: Any],
               let key = ["apiKey", "api_key", "token", "key", "accessToken", "auth_token"].compactMap({ glmString(object[$0]) }).first {
                return GLMCredential(token: key, baseURL: glmConsole(forProviderID: id), source: "OpenCode")
            }
        }
        return nil
    }

    /// The `zhipu` names sign into the China console, everything else the global one.
    static func glmConsole(forProviderID id: String) -> URL {
        id.hasPrefix("zhipu") ? URL(string: "https://open.bigmodel.cn")! : URL(string: "https://api.z.ai")!
    }

    static func glmIsZaiHost(_ host: String) -> Bool {
        host == "api.z.ai" || host.hasSuffix(".z.ai")
            || host == "open.bigmodel.cn" || host.hasSuffix(".bigmodel.cn")
    }

    /// The monitor lives at the console root; the path beside the key (e.g. /api/anthropic) is dropped.
    static func glmConsoleBase(from host: String) -> URL {
        host.hasSuffix("bigmodel.cn") ? URL(string: "https://open.bigmodel.cn")! : URL(string: "https://api.z.ai")!
    }

    /// Non-empty strings only: an empty key is a request that cannot succeed being sent all the same.
    static func glmString(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Ollama Cloud key

    /// The Ollama Cloud API key used directly, as upstream does — no Pi config needed.
    /// Sources in order: `OLLAMA_API_KEY`, then ollama's own sign-in file
    /// `~/.ollama/api_keys.json` (`{"keys":[{"type":"oas","value":"sk-…"}]}`);
    /// Pi's explicit ollama.com key remains a last-resort fallback via `context`.
    static func ollamaKey(home: URL, env: [String: String]) -> String? {
        if let key = env["OLLAMA_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if let data = try? file(home.appendingPathComponent(".ollama/api_keys.json")),
           let root = try? UsageParsing.object(data),
           let keys = root["keys"] as? [[String: Any]] {
            for entry in keys.prefix(10) {
                if let value = glmString(entry["value"]) { return value }
            }
        }
        return nil
    }
}

/// Reads ZCode's side of `~/.zcode/v2/credentials.json`: values wrapped as
/// `enc:v1:<iv>.<tag>.<ciphertext>` (base64url) sealed with AES-256-GCM under
/// the SHA-256 of a secret — `$ZCODE_CREDENTIAL_SECRET` when set, else a
/// `zcode-credential-fallback:darwin:<home>:<user>` derivation. A value that
/// does not decrypt is nil, never a guess. A value without the marker passes
/// through untouched: older builds wrote the token in the clear.
enum ZCodeCredentialCipher {
    static let prefix = "enc:v1:"
    static let secretEnvironmentKey = "ZCODE_CREDENTIAL_SECRET"

    static func isEncrypted(_ value: String) -> Bool { value.hasPrefix(prefix) }

    static func defaultSecret(env: [String: String],
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              username: String = NSUserName()) -> String {
        if let override = env[secretEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return "zcode-credential-fallback:darwin:\(home.path):\(username)"
    }

    static func decrypt(_ value: String, secret: String) -> String? {
        guard isEncrypted(value) else { return value }
        let parts = value.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = Data(base64url: String(parts[0])), iv.count == 12,
              let tag = Data(base64url: String(parts[1])), tag.count == 16,
              let ciphertext = Data(base64url: String(parts[2])) else { return nil }
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(sealed, using: key),
              let text = String(data: plain, encoding: .utf8) else { return nil }
        return text
    }
}

extension Data {
    /// Foundation decodes base64, not base64url; the alphabets differ in two characters and the padding.
    init?(base64url: String) {
        var base64 = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 1 else { return nil }
        base64 += String(repeating: "=", count: (4 - remainder) % 4)
        self.init(base64Encoded: base64)
    }
}
