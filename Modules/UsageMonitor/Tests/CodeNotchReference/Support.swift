// Test-only glue for unmodified upstream Foundation sources; never linked into VitaPet.
import Foundation

enum UsageProviderError: Error {
    case badResponse(status: Int)
    case nothingMetered(String)
}
enum UsageBand: String, Codable { case ample }
struct UsageMoneyBreakdown: Codable, Equatable, Sendable {
    let currency: String
    let spent: Double
    let remaining: Double
    var funded: Double { spent + remaining }
    var spentFraction: Double {
        guard funded > 0 else { return 0 }
        return min(max(spent / funded, 0), 1)
    }
}
enum L10n {
    static let locale = Locale(identifier: "en_US_POSIX")
    static func t(_ text: String, locale: Locale = locale) -> String { text }
}

extension String {
    /// Nil when this would be an empty plan line on the card.
    var nonEmptyPlan: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum Percent {
    /// The two halves of a used-fraction, as display text.
    static func halves(for fraction: Double) -> (used: String, left: String) {
        let value = fraction * 100
        let fractional = (value > 0 && value < 1) || (value > 99 && value < 100)
        guard fractional else {
            // The left half derives from the *rounded* used half, not from the
            // raw value — 9.5% used is "10% Used · 90% left", because that is
            // how the dashboard the user is comparing against does the maths.
            let used = Int(value.rounded())
            return ("\(used)", "\(max(0, 100 - used))")
        }
        let left = max(0, 100 - value)
        // "<0.1" has no number to subtract from a hundred, so the far half
        // makes the same claim from its own end: ">99.9".
        return (small(value), left > 99.9 ? ">99.9" : small(left))
    }

    /// One percentage, as display text — the ring's label.
    static func text(for fraction: Double) -> String {
        let value = fraction * 100
        guard value > 0, value < 1 else { return "\(Int(value.rounded()))" }
        return small(value)
    }

    /// One percentage with no decimals, for the menu bar, where a tenth is
    /// noise at a glance. Rounding never lands on the two figures that would
    /// say something else happened: "0" when a little has been used, or "100"
    /// while there is still room.
    static func whole(for fraction: Double) -> String {
        let value = max(0, fraction * 100)
        if value > 0, value < 1 { return "<1" }
        if value > 99, value < 100 { return "99" }
        return "\(Int(value.rounded()))"
    }

    private static func small(_ value: Double) -> String {
        if value <= 0 { return "0" }
        let tenths = (value * 10).rounded() / 10
        if tenths < 0.1 { return "<0.1" }
        if tenths > 99.9 { return ">99.9" }
        // Fixed locale: the decimal point is not up to the system settings,
        // any more than "%" is.
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tenths)
    }
}

/// One metered window a provider exposes — Claude has two (the rolling session
/// and the longer all-models window), others have one.
struct LimitWindow: Identifiable, Codable, Equatable {
    let id: String
    let group: String?
    let label: String
    /// 0...1+, where 1 means the limit is spent. Nil when the provider reports
    /// what is left but never says what the limit was — Perplexity does exactly
    /// this, and a percentage would have to invent the denominator.
    let usedFraction: Double?
    /// How many are left, when that is what the provider reports.
    let remaining: Int?
    /// How many have been spent, when the provider counts up rather than down
    /// and never states the ceiling. Cursor does this.
    let used: Int?
    /// Optional provider-specific value for count-only rows.
    let detail: String?
    /// Structured money data for providers whose account is metered in money.
    let money: UsageMoneyBreakdown?
    /// Optional display override for `used` — used when the raw count would
    /// be the wrong unit (e.g. a dollar balance formatted as "$14.28").
    let usedText: String?
    /// Nil when the provider does not say when the window rolls over.
    let resetsAt: Date?

    /// Exact cycle length when known; optional to keep older archives readable.
    let duration: TimeInterval?
    var bandOverride: UsageBand? = nil
    var prefersUsedText: Bool = false

    init(id: String, group: String? = nil, label: String, usedFraction: Double? = nil,
         remaining: Int? = nil, used: Int? = nil, usedText: String? = nil, detail: String? = nil,
         money: UsageMoneyBreakdown? = nil, resetsAt: Date? = nil,
         duration: TimeInterval? = nil, bandOverride: UsageBand? = nil,
         prefersUsedText: Bool = false) {
        self.id = id
        self.group = group
        self.label = label
        self.usedFraction = usedFraction
        self.remaining = remaining
        self.used = used
        self.usedText = usedText
        self.detail = detail
        self.money = money
        self.resetsAt = resetsAt
        self.duration = duration
        self.bandOverride = bandOverride
        self.prefersUsedText = prefersUsedText
    }

    enum CodingKeys: String, CodingKey {
        case id, group, label, usedFraction, remaining, used, detail, money, usedText, resetsAt, duration, bandOverride, prefersUsedText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.group = try container.decodeIfPresent(String.self, forKey: .group)
        self.label = try container.decode(String.self, forKey: .label)
        self.usedFraction = try container.decodeIfPresent(Double.self, forKey: .usedFraction)
        self.remaining = try container.decodeIfPresent(Int.self, forKey: .remaining)
        self.used = try container.decodeIfPresent(Int.self, forKey: .used)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.money = try container.decodeIfPresent(UsageMoneyBreakdown.self, forKey: .money)
        self.usedText = try container.decodeIfPresent(String.self, forKey: .usedText)
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.bandOverride = try container.decodeIfPresent(UsageBand.self, forKey: .bandOverride)
        self.prefersUsedText = try container.decodeIfPresent(Bool.self, forKey: .prefersUsedText) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(usedFraction, forKey: .usedFraction)
        try container.encodeIfPresent(remaining, forKey: .remaining)
        try container.encodeIfPresent(used, forKey: .used)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(money, forKey: .money)
        try container.encodeIfPresent(usedText, forKey: .usedText)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(bandOverride, forKey: .bandOverride)
        if prefersUsedText {
            try container.encode(prefersUsedText, forKey: .prefersUsedText)
        }
    }

    /// Whether this is a rolling five-hour window — the limit a coding session
    /// runs into first. Read from the length the provider reported rather than
    /// from an id, because every vendor names it differently: Claude's
    /// `session`, Codex's `primary`, Kimi's `rolling`.
    var isFiveHour: Bool {
        guard let duration else { return false }
        // A minute's slack: some vendors send the window as a start and an
        // end, and the difference is not always a whole number of seconds.
        return abs(duration - 5 * 3600) < 60
    }

    /// A count short enough to sit inside a 44 pt ring.
    ///
    /// Requests and credits are three or four digits and print verbatim; token
    /// counts run to seven, and "651061" under the ring is unreadable at that
    /// width. The threshold is 10 000 so no existing provider's number changes.
    static func compact(_ count: Int) -> String {
        if count < 10_000 { return "\(count)" }
        if count < 1_000_000 { return "\(count / 1_000)k" }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }

    /// What the tooltip says on the line under the bar.
    var summary: String { summary(locale: L10n.locale) }

    func summary(locale: Locale = L10n.locale) -> String {
        if let usedFraction {
            // Both ends of the same figure. Vendors do not agree on which to
            // show — Codex writes "87% remaining", Claude writes "% used" — so
            // a notch that picks one side leaves the user converting in their
            // head, and "12% Used" beside Codex's "87% remaining" reads as two
            // different numbers rather than one seen from either end. That is
            // what made a correct reading look wrong.
            let halves = Percent.halves(for: usedFraction)
            return L10n.t("\(halves.used)% Used · \(halves.left)% left", locale: locale)
        }
        if let remaining {
            return remaining < 10_000
                ? L10n.t("\(remaining) left", locale: locale)
                : L10n.t("\(Self.compact(remaining)) left", locale: locale)
        }
        if let used {
            if let usedText { return usedText }
            return used < 10_000
                ? L10n.t("\(used) used", locale: locale)
                : L10n.t("\(Self.compact(used)) used", locale: locale)
        }
        return L10n.t("No reading", locale: locale)
    }
}
