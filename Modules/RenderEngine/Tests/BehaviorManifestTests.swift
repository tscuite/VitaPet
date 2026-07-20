import Foundation
import XCTest
@testable import RenderEngine

final class BehaviorManifestTests: XCTestCase {
    private let expandedActionNames = [
        "blink",
        "sniff",
        "tailWag",
        "pawTap",
        "pounce",
        "crouch",
        "crawl",
        "nap",
        "dream",
        "beg",
        "nuzzle",
        "surprised",
        "blush",
        "proud",
        "melt",
        "sing",
        "meditate",
        "coffee",
        "snack",
        "stargaze",
        "sparkle",
        "slide",
        "pawReach",
        "guard",
        "danceCombo",
        "somersaultCombo",
        "boxingCombo",
        "parkourCombo",
        "partyCombo",
        "trainingCombo",
        "joySpinCombo"
    ]

    func testDecodeFromJSON() throws {
        guard let url = Bundle.module.url(
            forResource: "behavior",
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "behavior", withExtension: "json") else {
            return XCTFail("behavior.json not found in bundle resources")
        }

        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(BehaviorManifest.self, from: data)

        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertGreaterThanOrEqual(manifest.behaviors.count, 75)
        XCTAssertEqual(manifest.idleBehaviors.count, 3)
        XCTAssertEqual(manifest.behaviors["walk"]?.type, .move)
        XCTAssertEqual(manifest.behaviors["edgeBounce"]?.type, .edgeReaction)
        XCTAssertEqual(manifest.behaviors["lookAtCursor"]?.type, .track)
        XCTAssertEqual(manifest.behaviors["sitOnWindow"]?.type, .windowSit)
        XCTAssertEqual(manifest.behaviors["climb"]?.type, .windowClimb)
        for actionName in expandedActionNames {
            XCTAssertEqual(manifest.behaviors[actionName]?.type, .static, "Missing static behavior for \(actionName)")
        }
    }

    func testDefaultManifest() {
        let manifest = BehaviorManifest.defaultManifest()

        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertFalse(manifest.behaviors.isEmpty)
        XCTAssertFalse(manifest.idleBehaviors.isEmpty)
        XCTAssertGreaterThanOrEqual(manifest.behaviors.count, 75)
        XCTAssertEqual(manifest.idleBehaviors.count, 3)
        for actionName in expandedActionNames {
            XCTAssertEqual(manifest.behaviors[actionName]?.type, .static, "Missing static behavior for \(actionName)")
        }
    }

    func testBehaviorLookup() {
        let manifest = BehaviorManifest.defaultManifest()

        let walk = manifest.behaviors["walk"]
        XCTAssertEqual(walk?.type, .move)
        XCTAssertEqual(walk?.speed, 60)
        XCTAssertEqual(walk?.targetMode, "random")
        XCTAssertEqual(walk?.maxDistance, 200)
        XCTAssertEqual(walk?.minDistance, 50)
        XCTAssertEqual(walk?.animation, "walk")
        XCTAssertEqual(walk?.flipToDirection, true)
    }

    func testIdleBehaviors() {
        let manifest = BehaviorManifest.defaultManifest()

        let happyTotal = manifest.idleBehaviors["happy"]?.values.reduce(0, +) ?? 0
        let normalTotal = manifest.idleBehaviors["normal"]?.values.reduce(0, +) ?? 0
        let sadTotal = manifest.idleBehaviors["sad"]?.values.reduce(0, +) ?? 0

        XCTAssertGreaterThan(happyTotal, 103)
        XCTAssertGreaterThan(normalTotal, 102)
        XCTAssertGreaterThan(sadTotal, 94)
    }

    func testIdleBehaviorsIncludeAutomaticDanceCombo() {
        let manifest = BehaviorManifest.defaultManifest()

        XCTAssertGreaterThanOrEqual(manifest.idleBehaviors["happy"]?["danceCombo"] ?? 0, 12)
        XCTAssertGreaterThanOrEqual(manifest.idleBehaviors["happy"]?["joySpinCombo"] ?? 0, 8)
        XCTAssertGreaterThanOrEqual(manifest.idleBehaviors["normal"]?["danceCombo"] ?? 0, 8)
        XCTAssertGreaterThanOrEqual(manifest.idleBehaviors["normal"]?["joySpinCombo"] ?? 0, 3)
        XCTAssertGreaterThanOrEqual(manifest.idleBehaviors["sad"]?["danceCombo"] ?? 0, 2)
    }

    func testTailWagIdleWeightStaysSubtle() {
        let manifest = BehaviorManifest.defaultManifest()

        XCTAssertLessThanOrEqual(manifest.idleBehaviors["happy"]?["tailWag"] ?? 0, 1)
        XCTAssertLessThanOrEqual(manifest.idleBehaviors["normal"]?["tailWag"] ?? 0, 1)
    }

    func testLoadBundledManifest() {
        let manifest = SpritePackLoader.loadBundledBehaviorManifest()

        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertFalse(manifest.behaviors.isEmpty)
        XCTAssertFalse(manifest.idleBehaviors.isEmpty)
    }
}
