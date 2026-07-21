@testable import ChatUI
import XCTest

final class ChatAutoScrollPolicyTests: XCTestCase {
    func testStreamingFollowsNearBottomStopsForUserScrollAndRestoresAtBottom() {
        var policy = ChatAutoScrollPolicy(nearBottomThreshold: 72)

        XCTAssertTrue(policy.isNearBottom(bottomDistance: 60))
        XCTAssertFalse(policy.isNearBottom(bottomDistance: 90))
        policy.observeBottomProximity(isNearBottom: false)
        XCTAssertTrue(policy.shouldFollowStreaming, "content growth alone must not disable following")

        policy.userDidScroll(isNearBottom: false)
        XCTAssertFalse(policy.shouldFollowStreaming)
        policy.observeBottomProximity(isNearBottom: false)
        XCTAssertFalse(policy.shouldFollowStreaming)

        policy.observeBottomProximity(isNearBottom: true)
        XCTAssertTrue(policy.shouldFollowStreaming)

        policy.userDidScroll(bottomDistance: 120)
        XCTAssertFalse(policy.shouldFollowStreaming, "direct scroll geometry must override stale proximity")
    }

    func testViewportGeometryComputesBottomDistanceForBothCoordinateOrientations() {
        let flipped = ChatScrollViewportGeometry(
            documentMinY: 0,
            documentMaxY: 1_000,
            visibleMinY: 700,
            visibleMaxY: 900,
            isFlipped: true
        )
        let unflipped = ChatScrollViewportGeometry(
            documentMinY: 0,
            documentMaxY: 1_000,
            visibleMinY: 100,
            visibleMaxY: 300,
            isFlipped: false
        )

        XCTAssertEqual(flipped.bottomDistance, 100)
        XCTAssertEqual(unflipped.bottomDistance, 100)
    }
}
