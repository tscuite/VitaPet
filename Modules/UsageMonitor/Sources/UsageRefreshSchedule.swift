// CodeNotch 1.20.0 / 6e8b0f8 UsageStore's shipped defaults and pure scheduling decisions (MIT).
import Foundation

enum UsageRefreshSchedule {
    static let tickInterval: TimeInterval = 15
    static let busyInterval: TimeInterval = 30
    static let idleInterval: TimeInterval = 5 * 60
    static let staleAfter: TimeInterval = 15 * 60
    static let onLookInterval: TimeInterval = 15
    static let deadline: TimeInterval = 60

    static func shouldRefresh(isBusy: Bool, sinceLastAttempt: TimeInterval,
                              idleInterval: TimeInterval, busyInterval: TimeInterval = 0,
                              resetDue: Bool = false) -> Bool {
        if resetDue { return true }
        if isBusy { return sinceLastAttempt >= busyInterval }
        return sinceLastAttempt >= idleInterval
    }

    static func shouldRefreshOnEvent(sinceLastRefresh: TimeInterval, spacing: TimeInterval) -> Bool {
        sinceLastRefresh >= spacing
    }

    static func hasWindowRolledOver(in readings: [UsageReading], since last: Date?, at now: Date) -> Bool {
        guard let last else { return false }
        return readings.contains { reading in
            reading.limits.contains { window in
                guard let resetsAt = window.resetsAt else { return false }
                return resetsAt > last && resetsAt <= now
            }
        }
    }
}
