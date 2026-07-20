import Foundation

public struct ChatAppearanceSettings: Equatable, Sendable {
    public static let minimumOpacity = 0.55
    public static let maximumOpacity = 1.0

    public var translucencyEnabled: Bool
    public var opacity: Double

    public init(translucencyEnabled: Bool = false, opacity: Double = maximumOpacity) {
        self.translucencyEnabled = translucencyEnabled
        self.opacity = Self.normalizedOpacity(opacity)
    }

    public static func normalizedOpacity(_ value: Double) -> Double {
        guard value.isFinite else {
            return maximumOpacity
        }

        return max(minimumOpacity, min(maximumOpacity, value))
    }

    public static func directOpacityControlValue(translucencyEnabled: Bool, opacity: Double) -> Double {
        translucencyEnabled ? normalizedOpacity(opacity) : maximumOpacity
    }

    public static func settingsFromDirectOpacityControl(_ value: Double) -> ChatAppearanceSettings {
        let opacity = normalizedOpacity(value)
        let isFullyOpaque = abs(opacity - maximumOpacity) < 0.001
        return ChatAppearanceSettings(
            translucencyEnabled: !isFullyOpaque,
            opacity: opacity
        )
    }
}
