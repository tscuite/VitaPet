import Persistence
import XCTest

final class PersistenceWriteGateTests: XCTestCase {
    func testSealAndWait_waitsForAcceptedOperation() async throws {
        let gate = PersistenceWriteGate()
        let blocker = PersistenceOperationBlocker()
        let operation = try gate.submit {
            await blocker.waitUntilReleased()
        }

        await blocker.waitUntilStarted()
        let drain = Task {
            await gate.sealAndWait()
            await blocker.markDrainReturned()
        }

        await Task.yield()
        let didDrainBeforeRelease = await blocker.didDrainReturn
        XCTAssertFalse(didDrainBeforeRelease)
        await blocker.release()
        try await operation.value
        _ = await drain.value
        let didDrainAfterRelease = await blocker.didDrainReturn
        XCTAssertTrue(didDrainAfterRelease)
        XCTAssertEqual(gate.pendingCount(), 0)
    }

    func testSealAndWait_rejectsLateSubmission() async {
        let gate = PersistenceWriteGate()
        _ = await gate.sealAndWait()

        XCTAssertThrowsError(try gate.submit {}) { error in
            XCTAssertEqual(error as? PersistenceWriteGateError, .closed)
        }
    }
}

private actor PersistenceOperationBlocker {
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
