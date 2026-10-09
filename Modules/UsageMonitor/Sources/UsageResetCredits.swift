// Ported from CodeNotch 1.20.0 / 6e8b0f8 (MIT). See THIRD_PARTY_NOTICES.md.
// Adaptations: public token model, UsageLimit names, UI-localized labels, bounded input.
import Foundation

/// Unused rate-limit resets reported by a provider.
public struct UsageResetCredits: Codable, Equatable, Sendable {
    public struct Credit: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let status: String
        public let expiresAt: Date?
        public let count: Int

        public init(id: String, status: String, expiresAt: Date? = nil, count: Int = 1) {
            self.id = id
            self.status = status
            self.expiresAt = expiresAt
            self.count = count
        }
    }

    public let availableCount: Int
    public let credits: [Credit]
    /// A cached observation must stay dated even when usage itself refreshes.
    public var checkedAt: Date? = nil

    public init(availableCount: Int, credits: [Credit] = [], checkedAt: Date? = nil) {
        self.availableCount = availableCount
        self.credits = credits
        self.checkedAt = checkedAt
    }

    /// Credits still available, soonest expiry first.
    public var available: [Credit] {
        credits.filter { $0.status == "available" }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// Expiry still applies while UsageStore is showing the last good reading.
    /// Keep the reported total: Codex can return a truncated list of credits.
    public func unexpired(at now: Date) -> UsageResetCredits {
        let expired = available.filter { ($0.expiresAt ?? .distantFuture) <= now }
        return UsageResetCredits(
            availableCount: max(0, availableCount - expired.reduce(0) { $0 + $1.count }),
            credits: credits.filter { ($0.expiresAt ?? .distantFuture) > now },
            checkedAt: checkedAt
        )
    }

    public var nextExpiry: Date? { available.compactMap(\.expiresAt).min() }
}
