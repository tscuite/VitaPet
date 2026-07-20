import XCTest
@testable import RenderEngine

final class InteractionTextActionResolverTests: XCTestCase {
    func testDefaultDoubleClickTextsMapToDistinctActions() {
        let cases: [(String, AnimationState)] = [
            ("太开心啦！", .cheer),
            ("好喜欢你！", .love),
            ("嘻嘻~", .play),
            ("我们是好朋友！", .wave),
            ("开心到转圈圈~", .joySpinCombo),
        ]

        for (text, expectedState) in cases {
            XCTAssertEqual(
                InteractionTextActionResolver.resolveDoubleClickText(text).state,
                expectedState,
                text
            )
        }
    }

    func testExplicitActionTagOverridesKeywordAndCleansDisplayText() {
        let resolution = InteractionTextActionResolver.resolveDoubleClickText("开心到转圈圈~ [ACTION:love]")

        XCTAssertEqual(resolution.displayText, "开心到转圈圈~")
        XCTAssertEqual(resolution.state, .love)
        XCTAssertEqual(resolution.count, 1)
    }

    func testExplicitActionTagSupportsComboAliasesAndCount() {
        let resolution = InteractionTextActionResolver.resolveDoubleClickText("翻给你看 [ACTION:somersault:3]")

        XCTAssertEqual(resolution.displayText, "翻给你看")
        XCTAssertEqual(resolution.state, .somersaultCombo)
        XCTAssertEqual(resolution.count, 3)
    }

    func testKeywordResolverCoversCommonPetReactions() {
        let cases: [(String, AnimationState)] = [
            ("一起跳舞吧", .danceCombo),
            ("来个抱抱", .nuzzle),
            ("摸摸头~", .nuzzle),
            ("害羞了", .blush),
            ("你最棒啦", .proud),
            ("闪亮登场", .sparkle),
            ("摇摇尾巴", .tailWag),
            ("求求你啦", .beg),
            ("嗯嗯好的", .nod),
            ("不要不要", .headShake),
            ("唱首歌", .sing),
            ("饿了吗", .eat),
            ("喝点水", .drink),
            ("困困了", .sleep),
            ("吓一跳", .surprised),
            ("想一想", .think),
            ("送你礼物", .gift),
        ]

        for (text, expectedState) in cases {
            XCTAssertEqual(
                InteractionTextActionResolver.resolveDoubleClickText(text).state,
                expectedState,
                text
            )
        }
    }
}
