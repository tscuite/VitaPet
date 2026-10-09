import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum MemoryWorkerAuthMode: String, Codable, Sendable, CaseIterable {
    case bearer
    /// HMAC 请求签名鉴权（X-Auth-Timestamp/Nonce/Signature）
    case signed
}

public struct MemoryWorkerConfig: Codable, Sendable {
    public var enabled: Bool
    public var endpoint: String
    public var authMode: MemoryWorkerAuthMode
    public var secret: String
    public var namespace: String
    public var scope: String
    public var queryLimit: Int
    public var createHorizon: String

    public init(
        enabled: Bool,
        endpoint: String,
        authMode: MemoryWorkerAuthMode,
        secret: String,
        namespace: String = "default",
        scope: String = "general",
        queryLimit: Int = 50,
        createHorizon: String = "daily"
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.authMode = authMode
        self.secret = secret
        self.namespace = namespace
        self.scope = scope
        self.queryLimit = max(1, min(100, queryLimit))
        self.createHorizon = createHorizon
    }
}

public struct MemoryWorkerItem: Decodable, Sendable {
    public let id: Int?
    public let content: String
    /// pi 记忆模型字段：这条记忆是“关于谁”的（memory/user/failure）
    public let target: String?
    /// pi 记忆模型字段：标准分类（preference/insight/...）或扩展 slug
    public let category: String?
    /// metadata.importance 的宽松解析（Int/Double/String 都接受）
    public let importance: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case target
        case category
        case metadata
    }

    public init(
        id: Int?,
        content: String,
        target: String? = nil,
        category: String? = nil,
        importance: Int? = nil
    ) {
        self.id = id
        self.content = content
        self.target = target
        self.category = category
        self.importance = importance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try c.decode(String.self, forKey: .content)
        if let intId = try? c.decode(Int.self, forKey: .id) {
            self.id = intId
        } else if let s = try? c.decode(String.self, forKey: .id), let intId = Int(s) {
            self.id = intId
        } else {
            self.id = nil
        }
        self.target = try? c.decodeIfPresent(String.self, forKey: .target)
        self.category = try? c.decodeIfPresent(String.self, forKey: .category)
        if let metadata = (try? c.decodeIfPresent([String: FlexibleScalar].self, forKey: .metadata)) ?? nil {
            self.importance = metadata["importance"]?.intValue
        } else {
            self.importance = nil
        }
    }
}

/// 宽松标量：服务端 importance 可能是 0.9 / 1 / "1" 三种形态
private struct FlexibleScalar: Decodable {
    let intValue: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            intValue = i
        } else if let d = try? c.decode(Double.self) {
            intValue = Int(d.rounded())
        } else if let s = try? c.decode(String.self), let i = Int(s.trimmingCharacters(in: .whitespaces)) {
            intValue = i
        } else {
            intValue = nil
        }
    }
}

public actor MemoryWorkerService {
    private var config: MemoryWorkerConfig
    private let urlSession: URLSession

    public init(config: MemoryWorkerConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public func updateConfig(_ newConfig: MemoryWorkerConfig) {
        config = newConfig
    }

    public func queryMemories(
        q: String? = nil,
        target: String? = nil,
        category: String? = nil,
        limit: Int? = nil
    ) async throws -> [MemoryWorkerItem] {
        guard config.enabled else {
            return []
        }

        var request = URLRequest(url: try Self.buildURL(from: config.endpoint, path: "/api/memories/query"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedQuery = q?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestLimit = limit.map { max(1, min(100, $0)) } ?? max(1, min(100, config.queryLimit))
        let payload = QueryRequest(
            namespace: config.namespace,
            // 查询不带 scope：读全量远程记忆（pi 记忆的 scope=general）
            scope: nil,
            q: (trimmedQuery?.isEmpty == true) ? nil : trimmedQuery,
            target: target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : target,
            category: category?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : category,
            limit: requestLimit
        )
        request.httpBody = try JSONEncoder().encode(payload)
        try Self.applyAuthorization(to: &request, config: config)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        if let parsed = try? JSONDecoder().decode(QueryResponse.self, from: data) {
            return parsed.items
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let rawItems = obj["items"] as? [[String: Any]] {
                return rawItems.compactMap { Self.looseMemoryItem(from: $0) }
            }
            if let rawItems = obj["memories"] as? [[String: Any]] {
                return rawItems.compactMap { Self.looseMemoryItem(from: $0) }
            }
        }
        let preview = String(data: data.prefix(320), encoding: .utf8)
        throw MemoryWorkerServiceError.unexpectedCreateResponse(preview)
    }

    @discardableResult
    public func createMemory(
        content: String,
        target: String? = nil,
        category: String? = nil,
        failureReason: String? = nil,
        importance: Int? = nil,
        tags: [String] = ["auto"],
        metadata: [String: String]? = nil
    ) async throws -> MemoryWorkerItem {
        guard config.enabled else {
            throw MemoryWorkerServiceError.disabled
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw MemoryWorkerServiceError.invalidInput("content is empty")
        }

        var request = URLRequest(url: try Self.buildURL(from: config.endpoint, path: "/api/memories"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var combinedTags = tags
        if let category, !category.isEmpty, !combinedTags.contains(category) {
            combinedTags.append(category)
        }

        var combinedMetadata = metadata ?? [:]
        if let category, !category.isEmpty {
            combinedMetadata["category"] = category
        }
        if let importance {
            combinedMetadata["importance"] = String(max(1, min(3, importance)))
        }

        let payload = CreateRequest(
            namespace: config.namespace,
            scope: config.scope,
            content: trimmedContent,
            tags: combinedTags.isEmpty ? nil : combinedTags,
            metadata: combinedMetadata.isEmpty ? nil : combinedMetadata,
            horizon: config.createHorizon,
            target: target,
            category: category,
            failureReason: failureReason
        )
        request.httpBody = try JSONEncoder().encode(payload)
        try Self.applyAuthorization(to: &request, config: config)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        if data.isEmpty {
            return MemoryWorkerItem(id: nil, content: trimmedContent)
        }
        return try Self.decodeCreateMemoryItem(from: data, fallbackContent: trimmedContent)
    }

    /// PATCH /api/memories/:id —— 对应 agent 的 memory_replace 语义：
    /// 记忆内容过时就地改写，而不是追加一条矛盾记录。nil 字段不会下发。
    @discardableResult
    public func updateMemory(
        id: Int,
        content: String? = nil,
        target: String? = nil,
        category: String? = nil,
        importance: Int? = nil,
        tags: [String]? = nil,
        metadata: [String: String]? = nil
    ) async throws -> MemoryWorkerItem? {
        guard config.enabled else {
            throw MemoryWorkerServiceError.disabled
        }

        var request = URLRequest(url: try Self.buildURL(from: config.endpoint, path: "/api/memories/\(id)"))
        request.httpMethod = "PATCH"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var combinedMetadata = metadata ?? [:]
        if let importance {
            combinedMetadata["importance"] = String(max(1, min(3, importance)))
        }

        let payload = UpdateRequest(
            content: content?.trimmingCharacters(in: .whitespacesAndNewlines),
            target: target,
            category: category,
            tags: tags,
            metadata: combinedMetadata.isEmpty ? nil : combinedMetadata
        )
        request.httpBody = try JSONEncoder().encode(payload)
        try Self.applyAuthorization(to: &request, config: config)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        guard !data.isEmpty else { return nil }
        return try Self.decodeCreateMemoryItem(from: data, fallbackContent: content ?? "")
    }

    /// DELETE /api/memories/:id —— 对应 agent 的 memory_remove 语义。
    /// 返回 false 表示远端已不存在（404），视为幂等成功。
    @discardableResult
    public func deleteMemory(id: Int) async throws -> Bool {
        guard config.enabled else {
            throw MemoryWorkerServiceError.disabled
        }

        var request = URLRequest(url: try Self.buildURL(from: config.endpoint, path: "/api/memories/\(id)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        try Self.applyAuthorization(to: &request, config: config)

        do {
            let (data, response) = try await urlSession.data(for: request)
            try Self.validate(response: response, data: data)
            return true
        } catch MemoryWorkerServiceError.httpStatus(let status, _) where status == 404 {
            return false
        }
    }

    /// Workers vary: `{ "item": {...} }`, flat `{ "id","content" }`, `{ "ok": true }`, etc.
    private static func decodeCreateMemoryItem(from data: Data, fallbackContent: String) throws -> MemoryWorkerItem {
        let decoder = JSONDecoder()
        struct ItemEnvelope: Decodable {
            let item: MemoryWorkerItem
        }
        struct DataEnvelope: Decodable {
            let data: MemoryWorkerItem
        }
        struct MemoryEnvelope: Decodable {
            let memory: MemoryWorkerItem
        }
        if let env = try? decoder.decode(ItemEnvelope.self, from: data) {
            return env.item
        }
        if let env = try? decoder.decode(DataEnvelope.self, from: data) {
            return env.data
        }
        if let env = try? decoder.decode(MemoryEnvelope.self, from: data) {
            return env.memory
        }
        if let item = try? decoder.decode(MemoryWorkerItem.self, from: data) {
            return item
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(480), encoding: .utf8)
            throw MemoryWorkerServiceError.unexpectedCreateResponse(preview)
        }
        if let parsed = memoryItemFromLooseJSON(obj, fallbackContent: fallbackContent, allowStatusOnlyFallback: true) {
            return parsed
        }
        for key in ["memory", "data", "result", "record"] {
            if let nested = obj[key] as? [String: Any],
               let parsed = memoryItemFromLooseJSON(nested, fallbackContent: fallbackContent, allowStatusOnlyFallback: true) {
                return parsed
            }
        }
        let preview = String(data: data.prefix(480), encoding: .utf8)
        throw MemoryWorkerServiceError.unexpectedCreateResponse(preview)
    }

    private static func memoryItemFromLooseJSON(
        _ obj: [String: Any],
        fallbackContent: String,
        allowStatusOnlyFallback: Bool
    ) -> MemoryWorkerItem? {
        let id = parseLooseId(from: obj)
        if let content = obj["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MemoryWorkerItem(id: id, content: content)
        }
        for key in ["text", "body", "message", "value"] {
            if let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return MemoryWorkerItem(id: id, content: s)
            }
        }
        if allowStatusOnlyFallback,
           obj["ok"] as? Bool == true || obj["success"] as? Bool == true,
           !fallbackContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MemoryWorkerItem(id: id, content: fallbackContent)
        }
        return nil
    }

    private static func parseLooseId(from obj: [String: Any]) -> Int? {
        for key in ["id", "memory_id", "memoryId"] {
            if let i = obj[key] as? Int {
                return i
            }
            if let s = obj[key] as? String, let i = Int(s) {
                return i
            }
            if let d = obj[key] as? Double {
                return Int(d)
            }
        }
        return nil
    }

    private static func looseMemoryItem(from obj: [String: Any]) -> MemoryWorkerItem? {
        memoryItemFromLooseJSON(obj, fallbackContent: "", allowStatusOnlyFallback: false)
    }

    private static func buildURL(from endpoint: String, path: String) throws -> URL {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty,
              var components = URLComponents(string: trimmedEndpoint)
        else {
            throw MemoryWorkerServiceError.invalidEndpoint(endpoint)
        }

        let basePath = normalizedBasePath(from: components.path)
        components.path = (basePath.isEmpty ? "" : basePath) + path

        guard let url = components.url else {
            throw MemoryWorkerServiceError.invalidEndpoint(endpoint)
        }

        return url
    }

    private static func normalizedBasePath(from originalPath: String) -> String {
        var path = originalPath
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let lowercased = path.lowercased()
        if lowercased.hasSuffix("/api/memories/query") {
            path.removeLast("/api/memories/query".count)
        } else if lowercased.hasSuffix("/api/memories") {
            path.removeLast("/api/memories".count)
        }

        if path == "/" {
            return ""
        }

        return path
    }

    private static func applyAuthorization(to request: inout URLRequest, config: MemoryWorkerConfig) throws {
        switch config.authMode {
        case .bearer:
            let token = config.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw MemoryWorkerServiceError.missingCredentials("bearer")
            }

            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .signed:
            // 与 memory worker 的 requireSignedAuth 同一套规范：
            // canonical = method\npath+query\ntimestamp\nnonce\nbodyHash，HMAC-SHA256(secret) 十六进制
            let secret = config.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else {
                throw MemoryWorkerServiceError.missingCredentials("signed")
            }
            let method = (request.httpMethod ?? "GET").uppercased()
            guard let url = request.url else {
                throw MemoryWorkerServiceError.invalidEndpoint(config.endpoint)
            }
            var pathAndQuery = url.path
            if let query = url.query, !query.isEmpty {
                pathAndQuery += "?" + query
            }
            let bodyHash = Self.sha256Hex(request.httpBody ?? Data())
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let nonce = Self.randomHex(32)
            let canonical = [method, pathAndQuery, timestamp, nonce, bodyHash].joined(separator: "\n")
            let key = SymmetricKey(data: Data(secret.utf8))
            let code = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
            let signatureHex = code.map { String(format: "%02x", $0) }.joined()
            request.setValue(timestamp, forHTTPHeaderField: "X-Auth-Timestamp")
            request.setValue(nonce, forHTTPHeaderField: "X-Auth-Nonce")
            request.setValue(signatureHex, forHTTPHeaderField: "X-Auth-Signature")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in 0..<byteCount {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MemoryWorkerServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw MemoryWorkerServiceError.httpStatus(httpResponse.statusCode, body)
        }
    }

    private struct QueryRequest: Encodable {
        let namespace: String
        let scope: String?
        let q: String?
        let target: String?
        let category: String?
        let limit: Int
    }

    private struct CreateRequest: Encodable {
        let namespace: String
        let scope: String
        let content: String
        let tags: [String]?
        let metadata: [String: String]?
        let horizon: String
        let target: String?
        let category: String?
        let failureReason: String?

        enum CodingKeys: String, CodingKey {
            case namespace
            case scope
            case content
            case tags
            case metadata
            case horizon
            case target
            case category
            case failureReason = "failure_reason"
        }
    }

    /// PATCH 请求体：只编码非 nil 字段，避免把服务端的 category 意外清空
    private struct UpdateRequest: Encodable {
        let content: String?
        let target: String?
        let category: String?
        let tags: [String]?
        let metadata: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case content
            case target
            case category
            case tags
            case metadata
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(content, forKey: .content)
            try c.encodeIfPresent(target, forKey: .target)
            try c.encodeIfPresent(category, forKey: .category)
            try c.encodeIfPresent(tags, forKey: .tags)
            try c.encodeIfPresent(metadata, forKey: .metadata)
        }
    }

    private struct QueryResponse: Decodable {
        let item: MemoryWorkerItem?
        let items: [MemoryWorkerItem]
        let count: Int

        enum CodingKeys: String, CodingKey {
            case item
            case items
            case count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            item = try c.decodeIfPresent(MemoryWorkerItem.self, forKey: .item)
            items = try c.decodeIfPresent([MemoryWorkerItem].self, forKey: .items) ?? []
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? items.count
        }
    }
}

public extension MemoryWorkerService {
    /// VitaPet 分类 → pi 记忆模型（target + category）。以 pi 词汇为准：
    /// preference/insight 用标准词，event/todo/relationship 作为扩展 slug 保留语义。
    static func remoteTargetAndCategory(for category: MemoryCategory) -> (target: String, category: String?) {
        switch category {
        case .preference:
            return ("user", "preference")
        case .fact:
            return ("user", "insight")
        case .event:
            return ("memory", "event")
        case .todo:
            return ("memory", "todo")
        case .relationship:
            return ("memory", "relationship")
        }
    }

    /// pi 记忆模型 category → VitaPet 分类（同步回本地时用）。
    static func localCategory(fromRemoteCategory remote: String?) -> MemoryCategory {
        guard let remote, !remote.isEmpty else { return .fact }
        switch remote {
        case "preference":
            return .preference
        case "event":
            return .event
        case "todo":
            return .todo
        case "relationship":
            return .relationship
        default:
            // insight/fact/convention/... 统一落为事实
            return .fact
        }
    }
}

public enum MemoryWorkerServiceError: LocalizedError {
    case disabled
    case invalidEndpoint(String)
    case missingCredentials(String)
    case invalidInput(String)
    case httpStatus(Int, String?)
    case invalidResponse
    case unexpectedCreateResponse(String?)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Memory worker is disabled"
        case .invalidEndpoint(let endpoint):
            return "Invalid memory worker endpoint: \(endpoint)"
        case .missingCredentials(let mode):
            return "Missing credentials for \(mode) authentication"
        case .invalidInput(let reason):
            return "Invalid memory input: \(reason)"
        case .httpStatus(let status, let body):
            if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Memory worker returned HTTP \(status): \(body)"
            }
            return "Memory worker returned HTTP \(status)"
        case .invalidResponse:
            return "Memory worker returned an invalid response"
        case .unexpectedCreateResponse(let preview):
            if let preview, !preview.isEmpty {
                return "Memory worker create response could not be parsed: \(preview)"
            }
            return "Memory worker create response could not be parsed"
        }
    }
}
