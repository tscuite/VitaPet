import AppKit
@testable import ChatUI
import SwiftUI
import XCTest

@MainActor
final class ReusableHostingSurfaceTests: XCTestCase {
    func testFactoryRunsOnlyOnceAcrossRepeatedResolutions() {
        var factoryCallCount = 0
        let reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { content in
                factoryCallCount += 1
                return TestSurface(content: content)
            },
            update: { surface, content in
                surface.content = content
            }
        )

        _ = reusableSurface.resolve { "first" }
        reusableSurface.invalidate()
        _ = reusableSurface.resolve { "second" }
        reusableSurface.invalidate()
        _ = reusableSurface.resolve { "third" }

        XCTAssertEqual(factoryCallCount, 1)
    }

    func testInvalidationBeforeFirstResolutionStillUsesFactoryWithoutUpdating() {
        var factoryCallCount = 0
        var makeContentCallCount = 0
        var updateCallCount = 0
        let reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { content in
                factoryCallCount += 1
                return TestSurface(content: content)
            },
            update: { surface, content in
                updateCallCount += 1
                surface.content = content
            }
        )

        reusableSurface.invalidate()
        let first = reusableSurface.resolve {
            makeContentCallCount += 1
            return "first"
        }
        let second = reusableSurface.resolve {
            makeContentCallCount += 1
            return "clean"
        }

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(makeContentCallCount, 1)
        XCTAssertEqual(updateCallCount, 0)
        XCTAssertTrue(first === second)
    }

    func testCleanResolutionDoesNotMakeOrUpdateContent() {
        var makeContentCallCount = 0
        var updateCallCount = 0
        let reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { TestSurface(content: $0) },
            update: { surface, content in
                updateCallCount += 1
                surface.content = content
            }
        )

        let first = reusableSurface.resolve {
            makeContentCallCount += 1
            return "first"
        }
        let second = reusableSurface.resolve {
            makeContentCallCount += 1
            return "second"
        }

        XCTAssertEqual(makeContentCallCount, 1)
        XCTAssertEqual(updateCallCount, 0)
        XCTAssertEqual(first.content, "first")
        XCTAssertTrue(first === second)
    }

    func testInvalidationMakesAndUpdatesContentExactlyOnce() {
        var makeContentCallCount = 0
        var updatedContents: [String] = []
        let reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { TestSurface(content: $0) },
            update: { surface, content in
                updatedContents.append(content)
                surface.content = content
            }
        )

        let first = reusableSurface.resolve {
            makeContentCallCount += 1
            return "first"
        }
        reusableSurface.invalidate()
        let second = reusableSurface.resolve {
            makeContentCallCount += 1
            return "second"
        }
        _ = reusableSurface.resolve {
            makeContentCallCount += 1
            return "third"
        }

        XCTAssertEqual(makeContentCallCount, 2)
        XCTAssertEqual(updatedContents, ["second"])
        XCTAssertEqual(first.content, "second")
        XCTAssertTrue(first === second)
    }

    func testRepeatedInvalidationsCoalesceIntoOneContentUpdate() {
        var makeContentCallCount = 0
        var updateCallCount = 0
        let reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { TestSurface(content: $0) },
            update: { surface, content in
                updateCallCount += 1
                surface.content = content
            }
        )

        let surface = reusableSurface.resolve {
            makeContentCallCount += 1
            return "first"
        }
        reusableSurface.invalidate()
        reusableSurface.invalidate()
        reusableSurface.invalidate()
        _ = reusableSurface.resolve {
            makeContentCallCount += 1
            return "second"
        }
        _ = reusableSurface.resolve {
            makeContentCallCount += 1
            return "clean"
        }

        XCTAssertEqual(makeContentCallCount, 2)
        XCTAssertEqual(updateCallCount, 1)
        XCTAssertEqual(surface.content, "second")
    }

    func testFactoryInvalidationKeepsNextResolutionDirty() {
        var updateCallCount = 0
        var reusableSurface: ReusableHostingSurface<String, TestSurface>!
        reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { content in
                reusableSurface.invalidate()
                return TestSurface(content: content)
            },
            update: { surface, content in
                updateCallCount += 1
                surface.content = content
            }
        )

        let surface = reusableSurface.resolve { "first" }
        _ = reusableSurface.resolve { "second" }

        XCTAssertEqual(updateCallCount, 1)
        XCTAssertEqual(surface.content, "second")
    }

    func testUpdateInvalidationKeepsFollowingResolutionDirty() {
        var updateCallCount = 0
        var reusableSurface: ReusableHostingSurface<String, TestSurface>!
        reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { TestSurface(content: $0) },
            update: { surface, content in
                updateCallCount += 1
                surface.content = content
                if updateCallCount == 1 {
                    reusableSurface.invalidate()
                }
            }
        )

        let surface = reusableSurface.resolve { "first" }
        reusableSurface.invalidate()
        _ = reusableSurface.resolve { "second" }
        _ = reusableSurface.resolve { "third" }

        XCTAssertEqual(updateCallCount, 2)
        XCTAssertEqual(surface.content, "third")
    }

    func testRepeatedResolutionPreservesSurfaceIdentity() {
        let reusableSurface = ReusableHostingSurface<String, TestSurface>(
            factory: { TestSurface(content: $0) },
            update: { surface, content in
                surface.content = content
            }
        )

        let first = reusableSurface.resolve { "first" }
        reusableSurface.invalidate()
        let second = reusableSurface.resolve { "second" }

        XCTAssertTrue(first === second)
    }

    func testHostingSurfaceRevisionAdvancesViewIdentity() {
        var revision = HostingSurfaceRevision()
        let initialValue = revision.value

        revision.advance()
        let firstInvalidationValue = revision.value
        revision.advance()

        XCTAssertNotEqual(firstInvalidationValue, initialValue)
        XCTAssertNotEqual(revision.value, firstInvalidationValue)
    }

    func testVersionedHostingRootResetsStateOnlyWhenRevisionChanges() {
        _ = NSApplication.shared
        let recorder = HostingStateProbeRecorder()
        let host = NSHostingView(
            rootView: VersionedHostingRoot(
                revision: 0,
                content: StatefulHostingProbe(seed: 1, mutationToken: 0, recorder: recorder)
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            window.close()
        }
        window.contentView = host
        window.orderFront(nil)
        XCTAssertTrue(waitUntil {
            recorder.appearedStates == [1]
                && recorder.observations.last?.seed == 1
                && recorder.observations.last?.state == 1
        })

        host.rootView = VersionedHostingRoot(
            revision: 0,
            content: StatefulHostingProbe(seed: 1, mutationToken: 1, recorder: recorder)
        )
        XCTAssertTrue(waitUntil {
            recorder.observations.last?.seed == 1
                && recorder.observations.last?.state == 99
        })
        XCTAssertEqual(recorder.observations.last?.state, 99)

        host.rootView = VersionedHostingRoot(
            revision: 0,
            content: StatefulHostingProbe(seed: 2, mutationToken: 2, recorder: recorder)
        )
        XCTAssertTrue(waitUntil {
            recorder.observations.last?.seed == 2
                && recorder.observations.last?.state == 99
        })
        XCTAssertEqual(recorder.observations.last?.seed, 2)
        XCTAssertEqual(recorder.observations.last?.state, 99)
        XCTAssertEqual(recorder.appearedStates, [1])

        host.rootView = VersionedHostingRoot(
            revision: 1,
            content: StatefulHostingProbe(seed: 2, mutationToken: 2, recorder: recorder)
        )
        XCTAssertTrue(waitUntil {
            recorder.observations.last?.seed == 2
                && recorder.observations.last?.state == 2
                && recorder.appearedStates == [1, 2]
        })
        XCTAssertEqual(recorder.observations.last?.seed, 2)
        XCTAssertEqual(recorder.observations.last?.state, 2)
        XCTAssertEqual(recorder.appearedStates, [1, 2])
    }
}

private final class TestSurface {
    var content: String

    init(content: String) {
        self.content = content
    }
}

private final class HostingStateProbeRecorder {
    var observations: [(seed: Int, state: Int)] = []
    var appearedStates: [Int] = []
}

private struct HostingStateObserver: NSViewRepresentable {
    let seed: Int
    let state: Int
    let recorder: HostingStateProbeRecorder

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        recorder.observations.append((seed, state))
    }
}

private struct StatefulHostingProbe: View {
    let seed: Int
    let mutationToken: Int
    let recorder: HostingStateProbeRecorder
    @State private var state: Int

    init(seed: Int, mutationToken: Int, recorder: HostingStateProbeRecorder) {
        self.seed = seed
        self.mutationToken = mutationToken
        self.recorder = recorder
        _state = State(initialValue: seed)
    }

    var body: some View {
        VStack {
            Text("\(state)")
            HostingStateObserver(seed: seed, state: state, recorder: recorder)
        }
        .onAppear {
            recorder.appearedStates.append(state)
        }
        .onChange(of: mutationToken) { _, newValue in
            if newValue == 1 {
                state = 99
            }
        }
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 1.0,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}
