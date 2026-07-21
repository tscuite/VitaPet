import CoreGraphics
import XCTest
@testable import RenderEngine

final class MotionFramePlannerTests: XCTestCase {
    func testStepsUsesCeilingAndAtLeastOneStep() {
        XCTAssertEqual(MotionFramePlanner.steps(forDuration: 0, frameRate: 60), 1)
        XCTAssertEqual(MotionFramePlanner.steps(forDuration: 0.01, frameRate: 60), 1)
        XCTAssertEqual(MotionFramePlanner.steps(forDuration: 0.5, frameRate: 60), 30)
        XCTAssertEqual(MotionFramePlanner.steps(forDuration: 0.51, frameRate: 60), 31)
    }

    func testPointInterpolatesLinearlyAtMidpoint() {
        let start = CGPoint(x: 10, y: 20)
        let target = CGPoint(x: 110, y: 220)

        let point = MotionFramePlanner.point(from: start, to: target, step: 5, steps: 10)

        XCTAssertEqual(point.x, 60, accuracy: 0.0001)
        XCTAssertEqual(point.y, 120, accuracy: 0.0001)
    }

    func testPointClampsBeforeStartAndAfterCompletion() {
        let start = CGPoint(x: 4, y: 8)
        let target = CGPoint(x: 20, y: 40)

        XCTAssertEqual(MotionFramePlanner.point(from: start, to: target, step: -3, steps: 10), start)
        XCTAssertEqual(MotionFramePlanner.point(from: start, to: target, step: 12, steps: 10), target)
    }

    func testProgressUsesElapsedTimeAndClampsToMotionBounds() {
        XCTAssertEqual(MotionFramePlanner.progress(elapsed: -0.25, duration: 2), 0)
        XCTAssertEqual(MotionFramePlanner.progress(elapsed: 0.5, duration: 2), 0.25, accuracy: 0.0001)
        XCTAssertEqual(MotionFramePlanner.progress(elapsed: 3, duration: 2), 1)
        XCTAssertEqual(MotionFramePlanner.progress(elapsed: 0, duration: 0), 1)
    }

    func testPointUsesElapsedTimeInsteadOfDeliveredFrameCount() {
        let start = CGPoint(x: 10, y: 20)
        let target = CGPoint(x: 110, y: 220)

        let point = MotionFramePlanner.point(
            from: start,
            to: target,
            elapsed: 0.75,
            duration: 1.5
        )

        XCTAssertEqual(point.x, 60, accuracy: 0.0001)
        XCTAssertEqual(point.y, 120, accuracy: 0.0001)
    }

    func testMovementSessionRejectsSupersededAndCancelledTokens() {
        var session = MovementSessionTracker()

        let supersededToken = session.begin()
        let currentToken = session.begin()

        XCTAssertFalse(session.isCurrent(supersededToken))
        XCTAssertTrue(session.isCurrent(currentToken))

        session.cancel()

        XCTAssertFalse(session.isCurrent(currentToken))
    }
}
