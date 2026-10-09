// CodeNotch 1.20.0 / 6e8b0f8: unmodified pure UsageStore scheduling functions (MIT).
import Foundation
struct ProviderSnapshot { var windows: [LimitWindow] }
enum ReferenceSchedule {
    static func hasWindowRolledOver(in snapshots: [ProviderSnapshot], since last: Date?, at now: Date) -> Bool {
        guard let last else { return false }
        return snapshots.contains { snapshot in
            snapshot.windows.contains { window in
                guard let resetsAt = window.resetsAt else { return false }
                return resetsAt > last && resetsAt <= now
            }
        }
    }

    static func shouldRefresh(
        isBusy: Bool,
        sinceLastAttempt: TimeInterval,
        idleInterval: TimeInterval,
        busyInterval: TimeInterval = 0,
        resetDue: Bool = false
    ) -> Bool {
        if resetDue { return true }
        if isBusy { return sinceLastAttempt >= busyInterval }
        return sinceLastAttempt >= idleInterval
    }

    static func shouldRefreshOnEvent(sinceLastRefresh: TimeInterval,
                                     spacing: TimeInterval) -> Bool {
        sinceLastRefresh >= spacing
    }
}
