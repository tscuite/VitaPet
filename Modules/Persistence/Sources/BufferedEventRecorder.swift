import Foundation

public actor BufferedEventRecorder {
    public typealias Committer = @Sendable (EventRollupBatch) async throws -> EventBatchAcknowledgement

    private let commit: Committer
    private var buckets: [String: EventRollupBucket] = [:]
    private var representatives: [String: FileEventRepresentative] = [:]
    private var inFlight: EventRollupBatch?
    private var bufferedRecoverySnapshot: EventRollupBatch?
    private var flushTask: Task<EventBatchAcknowledgement?, Error>?
    private var flushGenerationID: UUID?
    private var sealed = false

    public init(commit: @escaping Committer) {
        self.commit = commit
    }

    public func record(_ delivery: FileEventDelivery) {
        guard !sealed, delivery.timestamp.timeIntervalSince1970.isFinite else { return }
        bufferedRecoverySnapshot = nil
        let timestamp = delivery.timestamp.timeIntervalSince1970
        let bucketStart = Int64(floor(timestamp / 3_600) * 3_600)
        let bucketKey = "fileChanged|\(bucketStart)"
        let old = buckets[bucketKey]?.eventCount ?? 0
        buckets[bucketKey] = EventRollupBucket(bucketStart: bucketStart, source: "fileChanged", eventCount: old + 1)
        let window = Int64(floor(timestamp / 10))
        let sampleKey = "fileChanged|\(window)|\(delivery.path)"
        representatives[sampleKey] = FileEventRepresentative(timestamp: timestamp, path: delivery.path, flags: delivery.flags)
        trimBuffers()
    }

    public func seal() { sealed = true }

    public func currentInFlightID() -> UUID? { inFlight?.id }

    public func flush() async throws -> EventBatchAcknowledgement? {
        if let flushTask, let flushGenerationID {
            return try await finishFlushTask(flushTask, generationID: flushGenerationID)
        }
        guard inFlight != nil || !buckets.isEmpty || !representatives.isEmpty else { return nil }
        if inFlight == nil { inFlight = makeBatch() }
        guard let batch = inFlight else { return nil }
        let task: Task<EventBatchAcknowledgement?, Error> = Task { [commit] in
            let acknowledgement = try await commit(batch)
            guard acknowledgement.id == batch.id,
                  acknowledgement.digest == batch.digest else {
                throw BufferedEventRecorderError.acknowledgementMismatch
            }
            return acknowledgement
        }
        flushTask = task
        flushGenerationID = batch.id
        return try await finishFlushTask(task, generationID: batch.id)
    }

    private func finishFlushTask(
        _ task: Task<EventBatchAcknowledgement?, Error>,
        generationID: UUID
    ) async throws -> EventBatchAcknowledgement? {
        do {
            let acknowledgement = try await task.value
            if flushGenerationID == generationID {
                guard inFlight?.id == generationID else {
                    throw BufferedEventRecorderError.acknowledgementMismatch
                }
                inFlight = nil
                flushTask = nil
                flushGenerationID = nil
            }
            return acknowledgement
        } catch {
            if flushGenerationID == generationID {
                flushTask = nil
                flushGenerationID = nil
            }
            throw error
        }
    }

    public func flushUntilEmpty() async throws {
        while inFlight != nil || !buckets.isEmpty || !representatives.isEmpty {
            _ = try await flush()
        }
    }

    /// Returns a non-destructive snapshot suitable for crash/quit recovery when
    /// SQLite cannot accept the final batch. The live buffers remain retryable.
    public func pendingBatchesForRecovery() -> [EventRollupBatch] {
        var batches: [EventRollupBatch] = []
        if let inFlight {
            batches.append(inFlight)
        }
        if !buckets.isEmpty || !representatives.isEmpty {
            batches.append(stableBufferedRecoverySnapshot())
        }
        return batches
    }

    private func makeBatch() -> EventRollupBatch {
        let batch = bufferedRecoverySnapshot ?? makeBatchSnapshot()
        bufferedRecoverySnapshot = nil
        buckets.removeAll(keepingCapacity: true)
        representatives.removeAll(keepingCapacity: true)
        return batch
    }

    private func stableBufferedRecoverySnapshot() -> EventRollupBatch {
        if let bufferedRecoverySnapshot {
            return bufferedRecoverySnapshot
        }
        let snapshot = makeBatchSnapshot()
        bufferedRecoverySnapshot = snapshot
        return snapshot
    }

    private func makeBatchSnapshot() -> EventRollupBatch {
        let sortedBuckets = buckets.values.sorted { ($0.bucketStart, $0.source) < ($1.bucketStart, $1.source) }
        let sortedRepresentatives = representatives.values.sorted {
            ($0.timestamp, $0.path, $0.flags) < ($1.timestamp, $1.path, $1.flags)
        }
        let digest = EventRollupDigest.calculate(
            buckets: sortedBuckets,
            representatives: sortedRepresentatives
        ) ?? ""
        return EventRollupBatch(id: UUID(), digest: digest, buckets: sortedBuckets, representatives: sortedRepresentatives)
    }

    private func trimBuffers() {
        if buckets.count > 721 {
            let oldest = buckets.keys.sorted { buckets[$0]!.bucketStart < buckets[$1]!.bucketStart }.prefix(buckets.count - 721)
            oldest.forEach { buckets.removeValue(forKey: $0) }
        }
        if representatives.count > 8_641 {
            let oldest = representatives.keys.sorted { representatives[$0]!.timestamp < representatives[$1]!.timestamp }.prefix(representatives.count - 8_641)
            oldest.forEach { representatives.removeValue(forKey: $0) }
        }
    }
}

private enum BufferedEventRecorderError: LocalizedError, Sendable {
    case acknowledgementMismatch
    var errorDescription: String? { "Buffered event recorder received a mismatched acknowledgement." }
}
