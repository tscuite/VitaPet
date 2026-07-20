import Foundation
import XCTest
@testable import RenderEngine

final class RenderCadencePlannerTests: XCTestCase {
    func testInvisibleWorkloadsAreFullySuspended() {
        let workloads: [RenderWorkload] = [
            .staticFrame,
            .spriteLoop(frameCount: 1, frameInterval: 0.02),
            .spriteLoop(frameCount: 2, frameInterval: 0.02),
            .continuous
        ]

        for workload in workloads {
            let cadence = RenderCadencePlanner.cadence(for: workload, isVisible: false)

            XCTAssertTrue(cadence.scenePaused)
            XCTAssertTrue(cadence.viewPaused)
        }
    }

    func testVisibleStaticAndSingleFrameLoopsSuspendAfterTheirFinalFrame() {
        let staticCadence = RenderCadencePlanner.cadence(for: .staticFrame, isVisible: true)
        let singleFrameCadence = RenderCadencePlanner.cadence(
            for: .spriteLoop(frameCount: 1, frameInterval: 0.02),
            isVisible: true
        )

        XCTAssertEqual(staticCadence, singleFrameCadence)
        XCTAssertEqual(staticCadence.framesPerSecond, 5)
        XCTAssertTrue(staticCadence.scenePaused)
        XCTAssertTrue(staticCadence.viewPaused)
    }

    func testSpriteLoopsUseSmallestSufficientCadenceTier() {
        XCTAssertEqual(spriteFPS(interval: 0.22), 5)
        XCTAssertEqual(spriteFPS(interval: 0.08), 15)
        XCTAssertEqual(spriteFPS(interval: 0.04), 30)
        XCTAssertEqual(spriteFPS(interval: 0.02), 60)
    }

    func testContinuousWorkUsesSixtyFramesPerSecond() {
        let cadence = RenderCadencePlanner.cadence(for: .continuous, isVisible: true)

        XCTAssertEqual(cadence.framesPerSecond, 60)
        XCTAssertFalse(cadence.scenePaused)
        XCTAssertFalse(cadence.viewPaused)
    }

    private func spriteFPS(interval: TimeInterval) -> Int {
        RenderCadencePlanner.cadence(
            for: .spriteLoop(frameCount: 2, frameInterval: interval),
            isVisible: true
        ).framesPerSecond
    }
}
