import Persistence
import XCTest

final class StorageMaintenanceCoordinatorTests: XCTestCase {
    func testConcurrentRunsShareOneOperation() async throws {
        let operation = MaintenanceOperationBlocker()
        let coordinator = StorageMaintenanceCoordinator {
            try await operation.run()
        }

        let first = Task { try await coordinator.run() }
        await operation.waitUntilStarted()
        let second = Task { try await coordinator.run() }
        await Task.yield()
        await operation.release()

        let firstReport = try await first.value
        let secondReport = try await second.value
        let runCount = await operation.runCount
        let isRunning = await coordinator.isRunning()
        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(runCount, 1)
        XCTAssertFalse(isRunning)
    }
}

private actor MaintenanceOperationBlocker {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var runCount = 0

    func run() async throws -> StorageMaintenanceReport {
        runCount += 1
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return StorageMaintenanceReport(
            archivedTurnCount: 1,
            rolledUpEventCount: 2,
            deletedEventCount: 3,
            deletedRollupCount: 4,
            reclaimedBytes: 5
        )
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
}
