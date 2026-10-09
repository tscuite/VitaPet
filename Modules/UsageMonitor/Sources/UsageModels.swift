import Foundation

public enum UsageProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor, copilot, ollama, deepseek
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .copilot: "GitHub Copilot"
        case .ollama: "Ollama"
        case .deepseek: "DeepSeek"
        }
    }
}

public enum UsageReadingStatus: String, Codable, Sendable {
    case disabled, notConnected, ready, stale, failed, rateLimited
}

public struct UsageLimit: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var usedFraction: Double?
    public var resetsAt: Date?
    public var group: String?
    public var duration: TimeInterval?
    public var remaining: Int?
    public var used: Int?
    public init(id: String, group: String? = nil, title: String, usedFraction: Double? = nil,
                remaining: Int? = nil, used: Int? = nil, resetsAt: Date? = nil, duration: TimeInterval? = nil) {
        self.id = id; self.title = title; self.group = group
        self.usedFraction = usedFraction.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) / 100 ? $0 : nil }
        self.resetsAt = resetsAt; self.duration = duration
        self.remaining = remaining; self.used = used
    }
}

public struct UsageReading: Identifiable, Codable, Equatable, Sendable {
    public var provider: UsageProviderID
    public var status: UsageReadingStatus
    public var limits: [UsageLimit]
    public var updatedAt: Date?
    public var detail: String?
    public var headlineID: String?
    public var plan: String?
    public var tokenUsage: CodexTokenUsage?
    public var resetCredits: UsageResetCredits?
    public var codexSettings: UsageCodexSettings?
    public var localSpend: UsageLocalSpend?
    public var id: String { provider.rawValue }
    // Named, not positional: a weekly- or Spark-only payload must not replace the session ring.
    public var headline: UsageLimit? {
        guard let headlineID else { return limits.first }
        return limits.first { $0.id == headlineID }
    }
    public var displayedHeadline: UsageLimit? {
        if provider == .codex, codexSettings?.weeklyHeadline == true {
            return limits.first { $0.id == "secondary" } ?? headline
        }
        return headline
    }
    public init(provider: UsageProviderID, status: UsageReadingStatus = .notConnected,
                limits: [UsageLimit] = [], updatedAt: Date? = nil, detail: String? = nil,
                headlineID: String? = nil, plan: String? = nil, tokenUsage: CodexTokenUsage? = nil,
                resetCredits: UsageResetCredits? = nil, codexSettings: UsageCodexSettings? = nil,
                localSpend: UsageLocalSpend? = nil) {
        self.provider = provider; self.status = status; self.limits = limits
        self.updatedAt = updatedAt; self.detail = detail; self.headlineID = headlineID
        self.plan = plan; self.tokenUsage = tokenUsage; self.resetCredits = resetCredits
        self.codexSettings = codexSettings; self.localSpend = localSpend
    }
}

public enum UsageBarEdge: String, Codable, CaseIterable, Sendable { case top, bottom }
public enum UsageBarSurfaceStyle: String, Codable, CaseIterable, Sendable { case glass, darkGlass, solid }

public struct UsageBarSettings: Codable, Equatable, Sendable {
    public var isVisible = true
    public var monitoringEnabled = false
    public var providers: [UsageProviderID] = [.codex, .cursor, .copilot, .ollama, .deepseek]
    public var edge: UsageBarEdge = .top
    public var surfaceStyle: UsageBarSurfaceStyle = .glass
    public var scale: Double = 1
    public var opacity: Double = 0.9
    public var horizontalPosition: Double = 0.5
    public var screenID: String? = nil
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isVisible, monitoringEnabled, providers, edge, surfaceStyle, scale, opacity, horizontalPosition, screenID
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? isVisible
        monitoringEnabled = try values.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? monitoringEnabled
        providers = try values.decodeIfPresent([UsageProviderID].self, forKey: .providers) ?? providers
        edge = try values.decodeIfPresent(UsageBarEdge.self, forKey: .edge) ?? edge
        surfaceStyle = try values.decodeIfPresent(UsageBarSurfaceStyle.self, forKey: .surfaceStyle) ?? .glass
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        horizontalPosition = try values.decodeIfPresent(Double.self, forKey: .horizontalPosition) ?? horizontalPosition
        screenID = try values.decodeIfPresent(String.self, forKey: .screenID)
    }

    /// Also applied after decoding: persisted layout values are untrusted.
    public mutating func normalize() {
        var seen = Set<UsageProviderID>()
        providers = providers.filter { seen.insert($0).inserted }
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        scale = clamp(scale, 0.6...1.8, 1)
        opacity = clamp(opacity, 0.3...1, 0.9)
        horizontalPosition = clamp(horizontalPosition, 0...1, 0.5)
        if let screenID, screenID.isEmpty || screenID.count > 64 || UInt32(screenID) == nil {
            self.screenID = nil
        }
    }
}

/// Sanitized failures only: never expose response bodies, credentials, or underlying URL errors.
public enum UsageFailure: Error, LocalizedError, Sendable {
    case notConnected, incompatiblePiCredential, credentialExpired, localUsageUnavailable, googleUnavailable, invalidResponse, transport, http(Int), rateLimited(Date)
    public var errorDescription: String? {
        switch self {
        case .notConnected: "No compatible Pi or supported tool sign-in file. Keychain access is disabled."
        case .incompatiblePiCredential: "This Pi login cannot query the official usage service. Gateway keys, commands and incompatible login types are not reused."
        case .credentialExpired: "The saved login expired. Pi or the owning tool must renew its own sign-in; VitaPet never refreshes credentials."
        case .localUsageUnavailable: "Local Pi usage could not be read. No account-balance request was made."
        case .googleUnavailable: "Google could not be reached. The usage request was skipped."
        case .invalidResponse: "The provider returned no supported usage data."
        case .transport: "Usage request failed or timed out. Try again later."
        case .http(let code): "The provider rejected the usage request (HTTP \(code))."
        case .rateLimited: "Rate limited. Refresh is paused until the provider's retry time."
        }
    }
}
