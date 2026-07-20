@testable import ChatUI
import XCTest

final class StreamingTextBatcherTests: XCTestCase {
    func testFirstChunkIsEmittedWithoutWaitingForAnotherChunk() async {
        let source = ControlledTextStream()
        let received = XCTestExpectation(description: "first snapshot received")
        let recorder = TextSnapshotRecorder()
        let consumer = Task {
            do {
                for try await snapshot in StreamingTextBatcher.snapshots(
                    from: source.stream,
                    minimumInterval: .seconds(60)
                ) {
                    recorder.record(snapshot)
                    received.fulfill()
                    break
                }
            } catch {
                // The assertion below reports a missing first snapshot.
            }
        }

        while !source.isReady {
            await Task.yield()
        }
        source.yield("Hello")
        await fulfillment(of: [received], timeout: 0.5)
        XCTAssertEqual(recorder.snapshot, "Hello")
        source.finish()
        consumer.cancel()
    }

    func testRapidChunksAreCoalescedIntoOneFinalSnapshot() async throws {
        let source = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Hello")
            continuation.yield(", ")
            continuation.yield("VitaPet")
            continuation.finish()
        }

        var snapshots: [String] = []
        for try await snapshot in StreamingTextBatcher.snapshots(
            from: source,
            minimumInterval: .seconds(60)
        ) {
            snapshots.append(snapshot)
        }

        XCTAssertEqual(snapshots.last, "Hello, VitaPet")
        XCTAssertLessThanOrEqual(snapshots.count, 2)
    }

    func testSourceErrorIsForwarded() async {
        struct StreamFailure: Error {}
        let source = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("partial")
            continuation.finish(throwing: StreamFailure())
        }

        do {
            for try await _ in StreamingTextBatcher.snapshots(from: source) {}
            XCTFail("Expected the source error to be forwarded")
        } catch is StreamFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpstreamCancellationIsForwardedAsFailure() async {
        let source = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("partial")
            continuation.finish(throwing: CancellationError())
        }

        do {
            for try await _ in StreamingTextBatcher.snapshots(
                from: source,
                minimumInterval: .seconds(60)
            ) {}
            XCTFail("Expected upstream cancellation to be forwarded")
        } catch is CancellationError {
            // Expected. Only cancellation caused by the downstream consumer is silent.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class ControlledTextStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    lazy var stream = AsyncThrowingStream<String, Error> { continuation in
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ chunk: String) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(chunk)
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.finish()
    }

    var isReady: Bool {
        lock.lock()
        let isReady = continuation != nil
        lock.unlock()
        return isReady
    }
}

private final class TextSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func record(_ snapshot: String) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    var snapshot: String? {
        lock.lock()
        let value = value
        lock.unlock()
        return value
    }
}
