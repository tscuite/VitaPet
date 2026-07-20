import Foundation
import Persistence
import XCTest

final class EventRollupTests: XCTestCase {
    func testSameBatchIsIdempotent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitapet-rollup-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = DatabaseManager(databaseURL: url)
        try await manager.initialize()
        let batch = EventRollupBatch(
            id: UUID(), digest: "digest", buckets: [EventRollupBucket(bucketStart: 0, source: "fileChanged", eventCount: 2)], representatives: []
        )
        XCTAssertEqual(try await manager.commitEventRollupBatch(batch), EventBatchAcknowledgement(id: batch.id, digest: batch.digest))
        XCTAssertEqual(try await manager.commitEventRollupBatch(batch), EventBatchAcknowledgement(id: batch.id, digest: batch.digest))
    }

    func testRecorderKeepsInFlightImmutableAcrossFailure() async throws {
        actor Calls { var batches: [EventRollupBatch] = []; func add(_ batch: EventRollupBatch) { batches.append(batch) } }
        let calls = Calls()
        let recorder = BufferedEventRecorder { batch in
            await calls.add(batch)
            throw NSError(domain: "test", code: 1)
        }
        await recorder.record(FileEventDelivery(path: "/tmp/a", flags: 1))
        let firstID = await recorder.currentInFlightID()
        _ = try? await recorder.flush()
        await recorder.record(FileEventDelivery(path: "/tmp/b", flags: 2))
        XCTAssertEqual(firstID, await recorder.currentInFlightID())
        XCTAssertEqual(1, await calls.batches.count)
    }
}
