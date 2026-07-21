import CoreGraphics
import Foundation

/// Invalidates delayed/timer-driven movement callbacks when a newer movement
/// supersedes them or movement is cancelled.
public struct MovementSessionTracker: Sendable {
    private var generation: UInt = 0

    public init() {}

    public mutating func begin() -> UInt {
        generation &+= 1
        return generation
    }

    public mutating func cancel() {
        generation &+= 1
    }

    public func isCurrent(_ token: UInt) -> Bool {
        token == generation
    }
}

/// Converts monotonic timestamps into bounded elapsed-time steps. A bounded
/// delta keeps a resumed run loop from teleporting moving windows after a long
/// system stall while still making normal movement independent of timer rate.
public struct ElapsedTickClock: Sendable {
    public let maximumDelta: TimeInterval
    private var lastTimestamp: TimeInterval?

    public init(maximumDelta: TimeInterval = 0.1) {
        self.maximumDelta = max(0, maximumDelta)
    }

    public mutating func reset(at timestamp: TimeInterval) {
        lastTimestamp = timestamp
    }

    public mutating func advance(to timestamp: TimeInterval) -> TimeInterval {
        guard let previousTimestamp = lastTimestamp else {
            lastTimestamp = timestamp
            return 0
        }
        guard timestamp >= previousTimestamp else {
            return 0
        }

        lastTimestamp = timestamp
        return min(timestamp - previousTimestamp, maximumDelta)
    }
}

/// Coordinates the two idempotence rules used by multi-pet movement loops:
/// each pet may receive at most one position write per tick, and its transition
/// into the following phase may happen at most once for the whole game.
public struct MovementTickCoordinator<ID: Hashable> {
    private var positionWritesThisTick: Set<ID> = []
    private var followTransitions: Set<ID> = []

    public init() {}

    public mutating func beginTick() {
        positionWritesThisTick.removeAll(keepingCapacity: true)
    }

    public mutating func claimPositionWrite(for id: ID) -> Bool {
        positionWritesThisTick.insert(id).inserted
    }

    public mutating func claimFollowTransition(for id: ID) -> Bool {
        followTransitions.insert(id).inserted
    }

    public mutating func reset() {
        positionWritesThisTick.removeAll(keepingCapacity: true)
        followTransitions.removeAll(keepingCapacity: true)
    }
}

public enum MotionFramePlanner {
    public static func steps(forDuration duration: TimeInterval, frameRate: TimeInterval) -> Int {
        guard duration > 0, frameRate > 0 else {
            return 1
        }
        return max(Int(ceil(duration * frameRate)), 1)
    }

    public static func point(from start: CGPoint, to target: CGPoint, step: Int, steps: Int) -> CGPoint {
        guard steps > 0 else {
            return target
        }

        let progress = min(1, max(0, CGFloat(step) / CGFloat(steps)))
        return point(from: start, to: target, progress: progress)
    }

    public static func progress(elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else {
            return 1
        }
        return min(1, max(0, CGFloat(elapsed / duration)))
    }

    public static func point(
        from start: CGPoint,
        to target: CGPoint,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> CGPoint {
        point(
            from: start,
            to: target,
            progress: progress(elapsed: elapsed, duration: duration)
        )
    }

    private static func point(from start: CGPoint, to target: CGPoint, progress: CGFloat) -> CGPoint {
        return CGPoint(
            x: start.x + (target.x - start.x) * progress,
            y: start.y + (target.y - start.y) * progress
        )
    }
}
