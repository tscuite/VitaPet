import XCTest
@testable import RenderEngine

final class ClickGesturePlannerTests: XCTestCase {
    func testDragStartAnimationIsSkippedForDoubleClick() {
        XCTAssertTrue(ClickGesturePlanner.shouldStartDragAnimation(clickCount: 1))
        XCTAssertFalse(ClickGesturePlanner.shouldStartDragAnimation(clickCount: 2))
        XCTAssertFalse(ClickGesturePlanner.shouldStartDragAnimation(clickCount: 3))
    }
}
