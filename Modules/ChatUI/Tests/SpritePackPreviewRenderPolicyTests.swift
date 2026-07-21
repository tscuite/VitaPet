import Foundation
@testable import ChatUI
import XCTest

@MainActor
final class SpritePackPreviewRenderPolicyTests: XCTestCase {
    func testImmediateEqualUpdateDoesNotRenderAfterMake() {
        let preview = makePreview(path: "/tmp/vitapet/packs/cat", size: 64)
        let coordinator = preview.makeCoordinator()
        var renderCount = 0

        preview.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }
        preview.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }

        XCTAssertEqual(renderCount, 1)
    }

    func testEquivalentStandardizedPackPathsDoNotRenderAgain() {
        let dottedPath = makePreview(path: "/tmp/vitapet/packs/../packs/cat", size: 64)
        let standardizedPath = makePreview(path: "/tmp/vitapet/packs/cat", size: 64)
        let coordinator = dottedPath.makeCoordinator()
        var renderCount = 0

        dottedPath.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }
        standardizedPath.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }

        XCTAssertEqual(renderCount, 1)
    }

    func testPackChangeRendersExactlyOnce() {
        let initial = makePreview(path: "/tmp/vitapet/packs/cat", size: 64)
        let changed = makePreview(path: "/tmp/vitapet/packs/dog", size: 64)
        let coordinator = initial.makeCoordinator()
        var renderCount = 0

        initial.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }
        changed.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }
        changed.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }

        XCTAssertEqual(renderCount, 2)
    }

    func testSizeChangeRendersExactlyOnce() {
        let initial = makePreview(path: nil, size: 64)
        let changed = makePreview(path: nil, size: 80)
        let coordinator = initial.makeCoordinator()
        var renderCount = 0

        initial.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }
        changed.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }
        changed.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }

        XCTAssertEqual(renderCount, 2)
    }

    func testUnchangedNaNSizeDoesNotRenderForever() {
        let preview = makePreview(path: nil, size: .nan)
        let coordinator = preview.makeCoordinator()
        var renderCount = 0

        preview.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }
        preview.renderIfNeeded(coordinator: coordinator) { renderCount += 1 }

        XCTAssertEqual(renderCount, 1)
    }

    private func makePreview(
        path: String?,
        size: CGFloat
    ) -> SpritePackPreviewView {
        SpritePackPreviewView(
            packDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
            previewSize: size
        )
    }
}
