import Foundation
import XCTest
@testable import RenderEngine

final class StaticRedrawCoordinatorTests: XCTestCase {
    func testVisibleStaticRequestTemporarilyUsesRenderCadence() {
        var coordinator = StaticRedrawCoordinator()

        let generation = coordinator.requestRedraw(for: .staticFrame, isVisible: true)

        XCTAssertNotNil(generation)
        XCTAssertEqual(
            coordinator.cadenceOverride,
            RenderCadence(framesPerSecond: 60, scenePaused: false, viewPaused: false)
        )
    }

    func testSecondFinishedUpdateProducesOneSettleToken() {
        var coordinator = StaticRedrawCoordinator()
        coordinator.requestRedraw(for: .staticFrame, isVisible: true)

        XCTAssertNil(coordinator.didFinishUpdate())
        let token = coordinator.didFinishUpdate()

        XCTAssertNotNil(token)
        XCTAssertNil(coordinator.didFinishUpdate())
    }

    func testCurrentTokenSettlesOnlyWhileVisibleAndStatic() throws {
        var coordinator = StaticRedrawCoordinator()
        coordinator.requestRedraw(for: .staticFrame, isVisible: true)
        XCTAssertNil(coordinator.didFinishUpdate())
        let token = try XCTUnwrap(coordinator.didFinishUpdate())

        XCTAssertTrue(coordinator.settle(token, workload: .staticFrame, isVisible: true))
        XCTAssertNil(coordinator.cadenceOverride)
    }

    func testRepeatedRequestRefreshesGenerationAndRestartsTwoCycleHandshake() throws {
        var coordinator = StaticRedrawCoordinator()
        let firstGeneration = try XCTUnwrap(
            coordinator.requestRedraw(for: .staticFrame, isVisible: true)
        )
        XCTAssertNil(coordinator.didFinishUpdate())

        let secondGeneration = try XCTUnwrap(
            coordinator.requestRedraw(for: .staticFrame, isVisible: true)
        )

        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertNil(coordinator.didFinishUpdate())
        XCTAssertNotNil(coordinator.didFinishUpdate())
    }

    func testMutationAfterFrameBeforeSettleInvalidatesOldToken() throws {
        var coordinator = StaticRedrawCoordinator()
        coordinator.requestRedraw(for: .staticFrame, isVisible: true)
        XCTAssertNil(coordinator.didFinishUpdate())
        let oldToken = try XCTUnwrap(coordinator.didFinishUpdate())

        coordinator.requestRedraw(for: .staticFrame, isVisible: true)

        XCTAssertFalse(coordinator.settle(oldToken, workload: .staticFrame, isVisible: true))
        XCTAssertNotNil(coordinator.cadenceOverride)
        XCTAssertNil(coordinator.didFinishUpdate())
        let currentToken = try XCTUnwrap(coordinator.didFinishUpdate())
        XCTAssertTrue(coordinator.settle(currentToken, workload: .staticFrame, isVisible: true))
    }

    func testHideAndActiveWorkloadCancelPendingSettle() throws {
        var coordinator = StaticRedrawCoordinator()
        coordinator.requestRedraw(for: .staticFrame, isVisible: true)
        XCTAssertNil(coordinator.didFinishUpdate())
        let hiddenToken = try XCTUnwrap(coordinator.didFinishUpdate())

        XCTAssertNil(coordinator.requestRedraw(for: .staticFrame, isVisible: false))
        XCTAssertNil(coordinator.cadenceOverride)
        XCTAssertFalse(coordinator.settle(hiddenToken, workload: .staticFrame, isVisible: true))

        coordinator.requestRedraw(for: .staticFrame, isVisible: true)
        XCTAssertNil(coordinator.didFinishUpdate())
        let activeToken = try XCTUnwrap(coordinator.didFinishUpdate())

        XCTAssertNil(coordinator.requestRedraw(for: .continuous, isVisible: true))
        XCTAssertNil(coordinator.cadenceOverride)
        XCTAssertFalse(coordinator.settle(activeToken, workload: .staticFrame, isVisible: true))
    }

    func testSingleFrameLoopAndStaticShowRequestRedraw() {
        var coordinator = StaticRedrawCoordinator()

        XCTAssertNotNil(
            coordinator.requestRedraw(
                for: .spriteLoop(frameCount: 1, frameInterval: 0.02),
                isVisible: true
            )
        )
        XCTAssertNil(
            coordinator.requestRedraw(
                for: .spriteLoop(frameCount: 2, frameInterval: 0.02),
                isVisible: true
            )
        )

        XCTAssertNil(coordinator.requestRedraw(for: .staticFrame, isVisible: false))
        XCTAssertNotNil(coordinator.requestRedraw(for: .staticFrame, isVisible: true))
    }
}
