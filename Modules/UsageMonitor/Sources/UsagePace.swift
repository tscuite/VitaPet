// CodeNotch 1.20.0 / 6e8b0f8 Features/UsagePace.swift (MIT).
import Foundation

public struct UsagePace: Sendable {
    public let percentagePoints: Double
    public var isDeficit: Bool { percentagePoints > 0 }
    public var value: String {
        let magnitude = abs(percentagePoints)
        let rounded = (magnitude * 10).rounded() / 10
        return rounded == 0 && magnitude > 0
            ? "<0.1"
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
                .replacingOccurrences(of: ".0", with: "")
    }
    public var summary: String { "\(value)% \(isDeficit ? "deficit" : "reserved")" }
}

extension UsageLimit {
    public func usagePace(now: Date) -> UsagePace? {
        guard let usedFraction, usedFraction.isFinite, usedFraction >= 0,
              let duration, duration.isFinite, duration > 0,
              let resetsAt else { return nil }
        let remainingTime = resetsAt.timeIntervalSince(now)
        guard remainingTime.isFinite, remainingTime > 0 else { return nil }
        let remainingFraction = min(remainingTime / duration, 1)
        let elapsedFraction = 1 - remainingFraction
        let spentFraction = min(usedFraction, 1)
        return UsagePace(percentagePoints: (spentFraction - elapsedFraction) * 100)
    }
}
