import XCTest
@testable import RenderEngine

final class ActionComboPlannerTests: XCTestCase {
    func testPlannerDefinesExpectedComboStates() {
        XCTAssertEqual(
            Set(ActionComboPlanner.comboStates.map(\.rawValue)),
            [
                "danceCombo",
                "somersaultCombo",
                "boxingCombo",
                "parkourCombo",
                "partyCombo",
                "trainingCombo",
                "joySpinCombo"
            ]
        )
    }

    func testJoySpinComboChainsCelebrateSpinSparkleAndProud() throws {
        let plan = try XCTUnwrap(ActionComboPlanner.plan(for: .joySpinCombo))

        XCTAssertEqual(plan.segments.map(\.state), [.celebrate, .spin, .sparkle, .tailWag, .proud])
        XCTAssertGreaterThan(plan.totalDuration, 2.6)
        XCTAssertTrue(plan.segments.allSatisfy { $0.duration > 0 })
    }

    func testDanceComboChainsDanceSlideSpinAndSparkle() throws {
        let plan = try XCTUnwrap(ActionComboPlanner.plan(for: .danceCombo))

        XCTAssertEqual(plan.segments.map(\.state), [.dance, .slide, .spin, .tailWag, .sparkle, .proud])
        XCTAssertGreaterThan(plan.totalDuration, 3.3)
        XCTAssertTrue(plan.segments.allSatisfy { $0.duration > 0 })
    }

    func testBoxingComboChainsGuardReachPunchAndProud() throws {
        let plan = try XCTUnwrap(ActionComboPlanner.plan(for: .boxingCombo))

        XCTAssertEqual(
            plan.segments.map(\.state),
            [.guardDuty, .pawTap, .pawReach, .punch, .pawReach, .punch, .guardDuty, .proud]
        )
        XCTAssertEqual(plan.segments.filter { $0.state == .punch }.count, 2)
        XCTAssertGreaterThan(plan.totalDuration, 2.0)
    }

    func testSomersaultComboScalesFlipDurationWithCount() throws {
        let oneFlip = try XCTUnwrap(ActionComboPlanner.plan(for: .somersaultCombo, count: 1))
        let fourFlips = try XCTUnwrap(ActionComboPlanner.plan(for: .somersaultCombo, count: 4))

        XCTAssertEqual(oneFlip.segments.map(\.state), [.crouch, .somersault, .pawReach, .punch, .sparkle])
        XCTAssertEqual(fourFlips.segments.map(\.state), oneFlip.segments.map(\.state))
        XCTAssertGreaterThan(fourFlips.totalDuration, oneFlip.totalDuration)
        XCTAssertEqual(fourFlips.windowTravelPoints, 200)
    }

    func testComboAliasesResolveToComboStates() {
        XCTAssertEqual(ActionComboPlanner.comboState(for: "dance"), .danceCombo)
        XCTAssertEqual(ActionComboPlanner.comboState(for: "跳舞"), .danceCombo)
        XCTAssertEqual(ActionComboPlanner.comboState(for: "celebrate"), .joySpinCombo)
        XCTAssertEqual(ActionComboPlanner.comboState(for: "开心转圈圈"), .joySpinCombo)
        XCTAssertEqual(ActionComboPlanner.comboState(for: "翻跟头"), .somersaultCombo)
        XCTAssertEqual(ActionComboPlanner.comboState(for: "打拳"), .boxingCombo)
        XCTAssertEqual(ActionComboPlanner.comboState(for: "boxing_combo"), .boxingCombo)
    }

    func testPlaybackStateRoutesLegacySingleActionNamesToCombos() {
        XCTAssertEqual(ActionComboPlanner.playbackState(for: "dance"), .danceCombo)
        XCTAssertEqual(ActionComboPlanner.playbackState(for: "celebrate"), .joySpinCombo)
        XCTAssertEqual(ActionComboPlanner.playbackState(for: "somersault"), .somersaultCombo)
        XCTAssertEqual(ActionComboPlanner.playbackState(for: "punch"), .boxingCombo)
        XCTAssertEqual(ActionComboPlanner.playbackState(for: "danceCombo"), .danceCombo)
        XCTAssertEqual(ActionComboPlanner.playbackState(for: "walk"), .walk)
    }

    func testManifestFramesUseExpandedActionFrames() throws {
        let somersaultFrames = try XCTUnwrap(ActionComboPlanner.manifestFrames(for: .somersaultCombo, prefix: "pet"))
        let joyFrames = try XCTUnwrap(ActionComboPlanner.manifestFrames(for: .joySpinCombo, prefix: "pet"))

        XCTAssertTrue(somersaultFrames.contains("pet_somersault_3"))
        XCTAssertTrue(joyFrames.contains("pet_sparkle_3"))
        XCTAssertTrue(joyFrames.contains("pet_tailWag_3"))
    }
}
