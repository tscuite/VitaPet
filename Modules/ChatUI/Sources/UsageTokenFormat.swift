// CodeNotch 1.20.0 / 6e8b0f8 TooltipCard UsageFormat (MIT).
import Foundation

enum UsageTokenFormat {
    static func tokens(_ value: Int?) -> String {
        guard let value else { return "—" }
        switch value {
        case 1_000_000_000...:
            return String(format: "%.2fB", locale: Locale(identifier: "en_US_POSIX"),
                          Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", locale: Locale(identifier: "en_US_POSIX"),
                          Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", locale: Locale(identifier: "en_US_POSIX"),
                          Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    static func duration(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0, seconds / 60 < Double(Int.max) else { return "—" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(minutes)m"
    }

    static func days(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)d"
    }
}
