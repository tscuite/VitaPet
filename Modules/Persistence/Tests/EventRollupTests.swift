import Foundation
import Persistence
import XCTest

final class EventRollupTests: XCTestCase {
    func testSameBatchIsIdempotent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitapet-rollup-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = DatabaseManager(databaseURL: url)
        try await manager.initialize()
        let buckets = [EventRollupBucket(bucketStart: 0, source: "fileChanged", eventCount: 2)]
        let digest = try XCTUnwrap(EventRollupDigest.calculate(buckets: buckets, representatives: []))
        let batch = EventRollupBatch(id: UUID(), digest: digest, buckets: buckets, representatives: [])
        let firstAcknowledgement = try await manager.commitEventRollupBatch(batch)
        let secondAcknowledgement = try await manager.commitEventRollupBatch(batch)
        let expectedAcknowledgement = EventBatchAcknowledgement(id: batch.id, digest: batch.digest)
        XCTAssertEqual(firstAcknowledgement, expectedAcknowledgement)
        XCTAssertEqual(secondAcknowledgement, expectedAcknowledgement)
    }

    func testCommitRejectsPayloadThatDoesNotMatchDigest() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitapet-rollup-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = DatabaseManager(databaseURL: url)
        try await manager.initialize()
        let originalBuckets = [
            EventRollupBucket(bucketStart: 0, source: "fileChanged", eventCount: 2)
        ]
        let digest = try XCTUnwrap(
            EventRollupDigest.calculate(buckets: originalBuckets, representatives: [])
        )
        let tampered = EventRollupBatch(
            id: UUID(),
            digest: digest,
            buckets: [EventRollupBucket(bucketStart: 0, source: "fileChanged", eventCount: 3)],
            representatives: []
        )

        do {
            _ = try await manager.commitEventRollupBatch(tampered)
            XCTFail("A payload/digest mismatch must be rejected")
        } catch {
            // Expected.
        }
    }

    func testRecorderKeepsInFlightImmutableAcrossFailure() async throws {
        actor Calls { var batches: [EventRollupBatch] = []; func add(_ batch: EventRollupBatch) { batches.append(batch) } }
        let calls = Calls()
        let recorder = BufferedEventRecorder { batch in
            await calls.add(batch)
            throw NSError(domain: "test", code: 1)
        }
        await recorder.record(FileEventDelivery(path: "/tmp/a", flags: 1))
        _ = try? await recorder.flush()
        let firstID = await recorder.currentInFlightID()
        await recorder.record(FileEventDelivery(path: "/tmp/b", flags: 2))
        _ = try? await recorder.flush()
        let currentInFlightID = await recorder.currentInFlightID()
        let batches = await calls.batches
        XCTAssertEqual(firstID, currentInFlightID)
        XCTAssertEqual(2, batches.count)
        XCTAssertEqual(batches[0].id, batches[1].id)
    }

    func testConcurrentFlushCallersBothRejectMismatchedAcknowledgement() async throws {
        let committer = BlockingRollupCommitter()
        let recorder = BufferedEventRecorder { batch in
            await committer.commit(batch)
        }
        await recorder.record(FileEventDelivery(path: "/tmp/a", flags: 1))

        let first = Task { try await recorder.flush() }
        await committer.waitUntilStarted()
        let second = Task { try await recorder.flush() }
        await Task.yield()
        await committer.releaseWithMismatchedAcknowledgement()

        do {
            _ = try await first.value
            XCTFail("Expected first flush to reject mismatched acknowledgement")
        } catch {}
        do {
            _ = try await second.value
            XCTFail("Expected second flush to reject mismatched acknowledgement")
        } catch {}

        let currentInFlightID = await recorder.currentInFlightID()
        let commitCount = await committer.commitCount
        XCTAssertNotNil(currentInFlightID)
        XCTAssertEqual(commitCount, 1)
    }

    func testPendingBatchesForRecovery_keepsInFlightAndBufferedEvents() async {
        let recorder = BufferedEventRecorder { _ in
            throw NSError(domain: "test", code: 1)
        }
        await recorder.record(FileEventDelivery(path: "/tmp/first", flags: 1))
        _ = try? await recorder.flush()
        await recorder.record(FileEventDelivery(path: "/tmp/second", flags: 2))

        let firstSnapshot = await recorder.pendingBatchesForRecovery()
        let secondSnapshot = await recorder.pendingBatchesForRecovery()

        XCTAssertEqual(firstSnapshot.count, 2)
        XCTAssertEqual(secondSnapshot.count, 2)
        XCTAssertEqual(firstSnapshot, secondSnapshot)
        XCTAssertEqual(firstSnapshot.flatMap(\.representatives).count, 2)
    }

    func testRecoverySnapshotsReuseBatchIDsWhenLiveFlushIsRetried() async throws {
        actor Committer {
            var shouldFail = true
            var committed: [EventRollupBatch] = []

            func commit(_ batch: EventRollupBatch) throws -> EventBatchAcknowledgement {
                if shouldFail {
                    throw NSError(domain: "test", code: 1)
                }
                committed.append(batch)
                return EventBatchAcknowledgement(id: batch.id, digest: batch.digest)
            }

            func allowCommits() { shouldFail = false }
        }

        let committer = Committer()
        let recorder = BufferedEventRecorder { batch in
            try await committer.commit(batch)
        }
        await recorder.record(FileEventDelivery(path: "/tmp/first", flags: 1))
        _ = try? await recorder.flush()
        await recorder.record(FileEventDelivery(path: "/tmp/second", flags: 2))
        let recoverySnapshot = await recorder.pendingBatchesForRecovery()

        await committer.allowCommits()
        try await recorder.flushUntilEmpty()
        let committed = await committer.committed

        XCTAssertEqual(committed.map(\.id), recoverySnapshot.map(\.id))
        XCTAssertEqual(committed.map(\.digest), recoverySnapshot.map(\.digest))
    }

    func testEventRollupRecoveryStore_roundTripsBatches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EventRollupRecoveryStore(
            fileURL: directory.appendingPathComponent("pending.json")
        )
        let batch = EventRollupBatch(
            id: UUID(),
            digest: "digest",
            buckets: [EventRollupBucket(bucketStart: 3_600, source: "fileChanged", eventCount: 2)],
            representatives: [FileEventRepresentative(timestamp: 3_601, path: "/tmp/a", flags: 1)]
        )

        try store.save([batch])
        let loaded = try store.load()
        XCTAssertEqual(loaded, [batch])
        try store.removeIfPresent()
        let afterRemoval = try store.load()
        XCTAssertTrue(afterRemoval.isEmpty)
    }
}

private actor BlockingRollupCommitter {
    private var batch: EventRollupBatch?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitContinuation: CheckedContinuation<EventBatchAcknowledgement, Never>?
    private(set) var commitCount = 0

    func commit(_ batch: EventRollupBatch) async -> EventBatchAcknowledgement {
        self.batch = batch
        commitCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            commitContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if batch != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseWithMismatchedAcknowledgement() {
        guard let batch, let continuation = commitContinuation else { return }
        commitContinuation = nil
        continuation.resume(
            returning: EventBatchAcknowledgement(id: UUID(), digest: batch.digest + "-wrong")
        )
    }
}
