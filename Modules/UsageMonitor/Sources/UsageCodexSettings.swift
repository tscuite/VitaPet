import Foundation

public enum UsageResetTimeFormat: String, Codable, Sendable {
    case automatic, remaining
}

/// Read-only display preferences from the installed CodeNotch. No credentials here.
/// Loaded only during an opted-in Codex fetch; fixtures pass their own values.
public struct UsageCodexSettings: Codable, Equatable, Sendable {
    public var showExtraLimits: Bool
    public var resetTimeFormat: UsageResetTimeFormat
    public var weeklyHeadline: Bool
    public var showUsagePace: Bool

    public init(showExtraLimits: Bool = true, resetTimeFormat: UsageResetTimeFormat = .automatic,
                weeklyHeadline: Bool = false, showUsagePace: Bool = false) {
        self.showExtraLimits = showExtraLimits
        self.resetTimeFormat = resetTimeFormat
        self.weeklyHeadline = weeklyHeadline
        self.showUsagePace = showUsagePace
    }

    static func read() -> UsageCodexSettings {
        let defaults = UserDefaults(suiteName: "com.vinz.codenotch")
        return UsageCodexSettings(
            showExtraLimits: defaults?.object(forKey: "showCodexExtraLimits") as? Bool ?? true,
            resetTimeFormat: defaults?.string(forKey: "resetTimeFormat").flatMap(UsageResetTimeFormat.init) ?? .automatic,
            weeklyHeadline: defaults?.bool(forKey: "weeklyHeadline") ?? false,
            showUsagePace: defaults?.bool(forKey: "showUsagePace") ?? false
        )
    }
}
