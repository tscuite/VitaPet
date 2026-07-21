import Foundation
import SpriteKit
import XCTest
@testable import RenderEngine

@MainActor
final class PetSceneTests: XCTestCase {
    func testActiveRenderingUsesDisplaySmoothCadence() {
        XCTAssertEqual(PetScene.activeFramesPerSecond, 60)
    }

    func testSceneUsesStableStaticCadenceBeforePresentation() {
        let scene = PetScene(size: CGSize(width: 64, height: 64), manifest: testManifest())

        XCTAssertEqual(
            scene.targetRenderCadence,
            RenderCadence(framesPerSecond: 5, scenePaused: true, viewPaused: true)
        )
        XCTAssertTrue(scene.isPaused)
    }

    func testIdleAnimationResetsRotationWithoutRequiringAView() {
        let scene = PetScene(size: CGSize(width: 64, height: 64), manifest: testManifest())

        scene.setRotation(.pi / 8)
        scene.playAnimation(for: .idle)

        XCTAssertEqual(scene.petNode.zRotation, 0, accuracy: 0.0001)
    }

    func testResetRestoresExplicitLeftFacingAfterAnEffectLosesScaleSign() {
        let scene = PetScene(size: CGSize(width: 64, height: 64), manifest: testManifest())

        scene.setFacing(.left)
        scene.petNode.xScale = 0.96
        scene.playAnimation(for: .idle)

        XCTAssertEqual(scene.petNode.xScale, -1, accuracy: 0.0001)
        XCTAssertEqual(scene.petNode.yScale, 1, accuracy: 0.0001)
    }

    func testSetFacingShortCircuitsWhenDirectionAndScaleAlreadyMatch() {
        let scene = PetScene(size: CGSize(width: 64, height: 64), manifest: testManifest())

        XCTAssertFalse(scene.setFacing(.right))
        XCTAssertTrue(scene.setFacing(.left))
        XCTAssertFalse(scene.setFacing(.left))
    }

    func testScaleBaselineKeepsLeftFacingSignAcrossPulseAndRestoreTargets() {
        let baseline = SpriteScaleBaseline(xScale: -1, yScale: 1)

        XCTAssertEqual(baseline.x(multiplier: 1.10), -1.10, accuracy: 0.0001)
        XCTAssertEqual(baseline.x(multiplier: 0.96), -0.96, accuracy: 0.0001)
        XCTAssertEqual(baseline.x(multiplier: 1), -1, accuracy: 0.0001)
        XCTAssertEqual(baseline.y(multiplier: 1.10), 1.10, accuracy: 0.0001)
        XCTAssertEqual(baseline.y(multiplier: 1), 1, accuracy: 0.0001)
    }

    private func testManifest() -> SpriteManifest {
        SpriteManifest(
            name: "Test",
            version: "1.0.0",
            states: [
                AnimationState.idle.rawValue: .init(
                    frames: ["missing_idle_frame"],
                    frameInterval: 0.1,
                    loop: true
                )
            ]
        )
    }
}
