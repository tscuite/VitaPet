import EventBus
import XCTest

final class EventPublicationTrackerTests: XCTestCase {
    func testStopAndDrain_waitsForAcceptedPublicationAndRejectsLateEvents() async {
        let eventBus = EventBus()
        let tracker = EventPublicationTracker()
        let blocker = TrackedEventBlocker()
        _ = await eventBus.subscribe { _ in
            await blocker.waitUntilReleased()
        }

        XCTAssertTrue(tracker.publish(.focusEntered, to: eventBus))
        await blocker.waitUntilStarted()
        tracker.stopAccepting()
        let drain = Task {
            await tracker.drain()
            await blocker.markDrainReturned()
        }

        await Task.yield()
        let didDrainBeforeRelease = await blocker.didDrainReturn
        XCTAssertFalse(didDrainBeforeRelease)
        XCTAssertFalse(tracker.publish(.focusExited, to: eventBus))
        await blocker.release()
        await drain.value
        let didDrainAfterRelease = await blocker.didDrainReturn
        XCTAssertTrue(didDrainAfterRelease)
    }
}

private actor TrackedEventBlocker {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didDrainReturn = false

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markDrainReturned() {
        didDrainReturn = true
    }
}
