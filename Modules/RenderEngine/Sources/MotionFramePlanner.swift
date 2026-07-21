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
