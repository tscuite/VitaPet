// Compile with -D USAGE_PRESENTATION_CHECKS alongside UsagePresentation.swift,
// linking the real UsageMonitor and Localization modules; no home or network reads.
#if USAGE_PRESENTATION_CHECKS
import Foundation
import Localization
import UsageMonitor

@main
struct UsagePresentationChecks {
    static func main() {
        L10n.locale = "en"
        precondition(UsagePresentation.percent(nil) == "—")
        precondition(UsagePresentation.percent(.nan) == "—")
        precondition(UsagePresentation.percent(.infinity) == "—")
        precondition(UsagePresentation.percent(.greatestFiniteMagnitude) == "—")
        precondition(UsagePresentation.percent(-0.1) == "—")
        precondition(UsagePresentation.percent(0) == "0%")
        precondition(UsagePresentation.percent(0.005) == "0.5%")
        precondition(UsagePresentation.percent(0.24) == "24%")
        precondition(UsagePresentation.percent(0.29) == "29%")
        precondition(UsagePresentation.percent(0.095) == "10%")
        precondition(UsagePresentation.percent(0.0001) == "<0.1%")
        precondition(UsagePresentation.percent(0.7999) == "80%")
        precondition(UsagePresentation.percent(0.8) == "80%")
        precondition(UsagePresentation.percent(0.9999) == "100%")
        precondition(UsagePresentation.percent(1) == "100%")
        precondition(UsagePresentation.percent(1.25) == "125%")
        precondition(UsagePresentation.budgetPercent(nil) == "—" && UsagePresentation.budgetPercent(.nan) == "—")
        precondition(UsagePresentation.budgetPercent(-1) == "—" && UsagePresentation.budgetPercent(0) == "0%")
        precondition(UsagePresentation.budgetPercent(24) == "24%")
        precondition(UsagePresentation.budgetPercent(80) == "80%")
        precondition(UsagePresentation.budgetPercent(Decimal(string: "0.0001")) == "<0.1%")
        precondition(UsagePresentation.budgetPercent(125) == "125%")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for locale in ["en", "zh-Hans"] {
            L10n.locale = locale
            precondition(UsagePresentation.countdown(to: now, now: now) == L10n.tr("usage.reset_due"))
            precondition(UsagePresentation.countdown(to: now.addingTimeInterval(3660), now: now)
                == String(format: L10n.tr("usage.reset_countdown"), 1, 1))
            for status in [UsageReadingStatus.disabled, .notConnected, .ready, .stale, .failed, .rateLimited] {
                precondition(!UsagePresentation.status(status).hasPrefix("usage."))
            }
            precondition(UsagePresentation.detail(UsageFailure.googleUnavailable.errorDescription!) == L10n.tr("usage.google_unavailable"))
            precondition(UsagePresentation.detail(UsageFailure.localUsageUnavailable.errorDescription!) == L10n.tr("usage.spend.unavailable"))
            precondition(!L10n.tr("usage.google_blocked").hasPrefix("usage."))
            for (notice, key) in [
                ("Copilot uses token-based billing; this endpoint reported no quota percentage.", "usage.copilot.token_billing"),
                ("Copilot reported unlimited quotas; no quota percentage is available.", "usage.copilot.unlimited"),
                ("Copilot did not report a usable quota limit or percentage.", "usage.copilot.no_quota")
            ] {
                precondition(!L10n.tr(key).hasPrefix("usage.") && UsagePresentation.detail(notice) == L10n.tr(key))
                precondition(UsagePresentation.detail("Last successful reading (cached). " + notice)
                    == L10n.tr("usage.cached_reading") + " " + L10n.tr(key))
            }
            for suffix in ["estimate", "today", "last7days", "last30days", "scan", "sources", "no_logs",
                           "no_records", "reference", "incomplete"] {
                precondition(!L10n.tr("usage.spend." + suffix).hasPrefix("usage."))
            }
            for style in UsageBarSurfaceStyle.allCases {
                for suffix in ["", "_hint"] {
                    precondition(!L10n.tr("usage.surface.\(style.rawValue)\(suffix)").hasPrefix("usage."))
                }
            }
        }
        for provider in UsageProviderID.allCases {
            precondition(!UsagePresentation.symbol(provider).isEmpty)
        }
        print("UsagePresentation checks passed: unknown/invalid, small/threshold/over-limit percentages, reset countdown, bilingual statuses, glyph mappings")
    }
}
#endif
