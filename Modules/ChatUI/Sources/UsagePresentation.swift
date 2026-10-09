import Foundation
import Localization
import UsageMonitor

/// Presentation uses consumed quota throughout; unknown values never become zero.
enum UsagePresentation {
    static func fraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func percent(_ value: Double?) -> String {
        guard let value = fraction(value) else { return "—" }
        let text = UsagePercent.text(for: value)
        return text == "—" ? text : text + "%"
    }

    /// DeepSeek spend is a percentage of a fixed US$100 budget; unknown values stay "—".
    static func budgetPercent(_ amount: Decimal?) -> String {
        guard let amount, !amount.isNaN, amount >= 0 else { return "—" }
        return percent(NSDecimalNumber(decimal: amount / 100).doubleValue)
    }

    static func detail(_ value: String) -> String {
        value.replacingOccurrences(of: UsageFailure.googleUnavailable.errorDescription!, with: L10n.tr("usage.google_unavailable"))
            .replacingOccurrences(of: UsageFailure.localUsageUnavailable.errorDescription!, with: L10n.tr("usage.spend.unavailable"))
            .replacingOccurrences(of: "Last successful reading (cached).", with: L10n.tr("usage.cached_reading"))
            .replacingOccurrences(of: "Copilot uses token-based billing; this endpoint reported no quota percentage.", with: L10n.tr("usage.copilot.token_billing"))
            .replacingOccurrences(of: "Copilot reported unlimited quotas; no quota percentage is available.", with: L10n.tr("usage.copilot.unlimited"))
            .replacingOccurrences(of: "Copilot did not report a usable quota limit or percentage.", with: L10n.tr("usage.copilot.no_quota"))
    }

    static func status(_ status: UsageReadingStatus) -> String {
        L10n.tr("usage.status.\(status.rawValue)")
    }

    static func symbol(_ provider: UsageProviderID) -> String {
        switch provider {
        case .codex: "command"
        case .claude: "sun.max"
        case .cursor: "cursorarrow"
        case .copilot: "eyeglasses"
        case .ollama: "hare"
        case .deepseek: "water.waves"
        }
    }

    static func countdown(to date: Date, now: Date) -> String {
        let minutes = ceil(date.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return L10n.tr("usage.reset_due") }
        let hours = floor(minutes / 60)
        return String(format: L10n.tr("usage.reset_countdown"), Int(hours), Int(minutes.truncatingRemainder(dividingBy: 60)))
    }
}
