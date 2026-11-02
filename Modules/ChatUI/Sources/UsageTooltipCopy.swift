import Foundation
import Localization
import UsageMonitor

/// JSON-localization adapters for the original CodeNotch card copy.
enum UsageTooltipCopy {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: L10n.tr(key), locale: Locale(identifier: L10n.locale), arguments: arguments)
    }

    static func windowTitle(_ title: String) -> String {
        switch title {
        case "Current session": return L10n.tr("usage.codex.current_session")
        case "Longer window": return L10n.tr("usage.codex.longer_window")
        case "Weekly limit": return L10n.tr("usage.codex.weekly")
        case "Monthly limit": return L10n.tr("usage.codex.monthly")
        case "Credits": return L10n.tr("usage.codex.credits")
        // GLM's own window names, matching upstream's wording.
        case "Weekly": return L10n.tr("usage.glm.weekly")
        case "MCP (1 month)": return L10n.tr("usage.glm.mcp")
        // Claude's session/weekly wording and Ollama's metered windows.
        case "5h session", "session": return L10n.tr("usage.codex.current_session")
        case "Weekly · all models", "weekly all": return L10n.tr("usage.claude.all_models")
        case "Monthly usage": return L10n.tr("usage.ollama.monthly")
        case "Session usage": return L10n.tr("usage.ollama.session")
        case "Weekly usage": return L10n.tr("usage.ollama.weekly")
        default:
            if title.hasSuffix(" h)") {
                return format("usage.glm.usage_hours", String(title.dropLast(3)).replacingOccurrences(of: "Usage (", with: ""))
            }
            if title.hasSuffix(" wk)") {
                return format("usage.glm.usage_weeks", String(title.dropLast(4)).replacingOccurrences(of: "Usage (", with: ""))
            }
            for (suffix, key) in [("m limit", "minutes"), ("h limit", "hours"), ("d limit", "days")] {
                if title.hasSuffix(suffix) {
                    return format("usage.codex.limit_\(key)", String(title.dropLast(suffix.count)))
                }
            }
            return title
        }
    }

    static func summary(_ limit: UsageLimit) -> String {
        if let fraction = limit.usedFraction {
            let halves = UsagePercent.halves(for: fraction)
            return format("usage.codex.used_left", halves.used, halves.left)
        }
        if let remaining = limit.remaining { return format("usage.codex.left", remaining) }
        if let used = limit.used { return format("usage.codex.used", used) }
        return L10n.tr("usage.no_reading")
    }

    // Original ElapsedCopy rounding; a cached reading stays visibly dated in the header.
    static func age(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 45 { return L10n.tr("usage.codex.just_now") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return format("usage.codex.age_minutes", max(1, minutes)) }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? format("usage.codex.age_hours", hours)
            : format("usage.codex.age_hours_minutes", hours, rest)
    }
}
