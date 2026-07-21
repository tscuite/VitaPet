import Foundation
import Persistence
import XCTest

final class RemoteMemoryBootstrapCoordinatorTests: XCTestCase {
    func testRemoteBootstrapStartsOnlyAfterVisibleUIAndOnlyOnce() async {
        let coordinator = RemoteMemoryBootstrapCoordinator()
        let recorder = BootstrapEventRecorder()

        let prematureStart = await coordinator.startIfReady {
            await recorder.append(.remoteBootstrap)
        }
        XCTAssertFalse(prematureStart)

        await recorder.append(.localMemoryContext)
        await recorder.append(.visibleUI)
        await coordinator.markVisibleUIReady()

        let firstStart = await coordinator.startIfReady {
            await recorder.append(.remoteBootstrap)
        }
        let duplicateStart = await coordinator.startIfReady {
            await recorder.append(.duplicateBootstrap)
        }

        XCTAssertTrue(firstStart)
        XCTAssertFalse(duplicateStart)
        await recorder.waitForEventCount(3)
        let startupEvents = await recorder.events
        XCTAssertEqual(
            startupEvents,
            [.localMemoryContext, .visibleUI, .remoteBootstrap]
        )

        await coordinator.cancelAndWait()
    }

    func testCancelAndWaitJoinsRunningBootstrap() async {
        let coordinator = RemoteMemoryBootstrapCoordinator()
        let recorder = BootstrapEventRecorder()
        let cancellation = CancellationSignal()
        let releaseGate = BootstrapReleaseGate()
        await coordinator.markVisibleUIReady()

        let didStart = await coordinator.startIfReady {
            await recorder.append(.remoteBootstrap)
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    await Task.yield()
                }
                await releaseGate.wait()
                await recorder.append(.operationFinished)
            } onCancel: {
                cancellation.signal()
            }
        }
        XCTAssertTrue(didStart)
        await recorder.waitForEventCount(1)

        let shutdown = Task {
            await coordinator.cancelAndWait()
            await recorder.append(.shutdownReturned)
        }
        await cancellation.wait()
        let eventsBeforeRelease = await recorder.events
        XCTAssertEqual(eventsBeforeRelease, [.remoteBootstrap])

        await releaseGate.release()
        await shutdown.value
        let shutdownEvents = await recorder.events
        XCTAssertEqual(
            shutdownEvents,
            [.remoteBootstrap, .operationFinished, .shutdownReturned]
        )
    }
}

private enum BootstrapEvent: Equatable, Sendable {
    case localMemoryContext
    case visibleUI
    case remoteBootstrap
    case duplicateBootstrap
    case operationFinished
    case shutdownReturned
}

private actor BootstrapEventRecorder {
    private(set) var events: [BootstrapEvent] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ event: BootstrapEvent) {
        events.append(event)
        let ready = waiters.filter { events.count >= $0.count }
        waiters.removeAll { events.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForEventCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor BootstrapReleaseGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending: [CheckedContinuation<Void, Never>]
        lock.lock()
        isSignalled = true
        pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !signalled() else { return }
        await withCheckedContinuation { continuation in
            install(continuation)
        }
    }

    private func signalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSignalled
    }

    private func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isSignalled {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }
}
