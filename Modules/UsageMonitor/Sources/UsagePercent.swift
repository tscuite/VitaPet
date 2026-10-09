// Ported from CodeNotch 1.20.0 / 6e8b0f8 (MIT). See THIRD_PARTY_NOTICES.md.
// Adaptations: public token model, UsageLimit names, UI-localized labels, bounded input.
import Foundation

public enum UsagePercent {
    /// The two halves of a used-fraction, as display text.
    public static func halves(for fraction: Double) -> (used: String, left: String) {
        guard fraction.isFinite, fraction >= 0, fraction < Double(Int.max) / 100 else {
            return ("—", "—")
        }
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
    public static func text(for fraction: Double) -> String {
        guard fraction.isFinite, fraction >= 0, fraction < Double(Int.max) / 100 else { return "—" }
        let value = fraction * 100
        guard value > 0, value < 1 else { return "\(Int(value.rounded()))" }
        return small(value)
    }

    /// One percentage with no decimals, for the menu bar, where a tenth is
    /// noise at a glance. Rounding never lands on the two figures that would
    /// say something else happened: "0" when a little has been used, or "100"
    /// while there is still room.
    public static func whole(for fraction: Double) -> String {
        guard fraction.isFinite, fraction >= 0, fraction < Double(Int.max) / 100 else { return "—" }
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
