import Foundation

struct ChatScrollViewportGeometry: Equatable, Sendable {
    let documentMinY: Double
    let documentMaxY: Double
    let visibleMinY: Double
    let visibleMaxY: Double
    let isFlipped: Bool

    var bottomDistance: Double {
        let distance = isFlipped
            ? documentMaxY - visibleMaxY
            : visibleMinY - documentMinY
        return max(0, distance)
    }
}

/// Keeps stream-following tied to user intent instead of transient content-growth geometry.
struct ChatAutoScrollPolicy: Equatable, Sendable {
    let nearBottomThreshold: Double
    private(set) var shouldFollowStreaming: Bool

    init(nearBottomThreshold: Double = 72, shouldFollowStreaming: Bool = true) {
        self.nearBottomThreshold = nearBottomThreshold
        self.shouldFollowStreaming = shouldFollowStreaming
    }

    func isNearBottom(bottomDistance: Double) -> Bool {
        bottomDistance <= nearBottomThreshold
    }

    /// Geometry may move away from the viewport solely because streamed content grew.
    /// It may safely restore following at the bottom, but only user input may disable it.
    mutating func observeBottomProximity(isNearBottom: Bool) {
        if isNearBottom {
            shouldFollowStreaming = true
        }
    }

    mutating func userDidScroll(isNearBottom: Bool) {
        shouldFollowStreaming = isNearBottom
    }

    mutating func userDidScroll(bottomDistance: Double) {
        userDidScroll(isNearBottom: isNearBottom(bottomDistance: bottomDistance))
    }
}
