import CryptoKit
import Foundation

public actor BufferedEventRecorder {
    public typealias Committer = @Sendable (EventRollupBatch) async throws -> EventBatchAcknowledgement

    private let commit: Committer
    private var buckets: [String: EventRollupBucket] = [:]
    private var representatives: [String: FileEventRepresentative] = [:]
    private var inFlight: EventRollupBatch?
    private var flushTask: Task<EventBatchAcknowledgement?, Error>?
    private var sealed = false

    private struct CanonicalBatch: Encodable {
        let buckets: [EventRollupBucket]
        let representatives: [FileEventRepresentative]
    }

    public init(commit: @escaping Committer) {
        self.commit = commit
    }

    public func record(_ delivery: FileEventDelivery) {
        guard !sealed, delivery.timestamp.timeIntervalSince1970.isFinite else { return }
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
        if let flushTask { return try await flushTask.value }
        guard inFlight != nil || !buckets.isEmpty || !representatives.isEmpty else { return nil }
        if inFlight == nil { inFlight = makeBatch() }
        guard let batch = inFlight else { return nil }
        let task: Task<EventBatchAcknowledgement?, Error> = Task { [commit] in
            return try await commit(batch)
        }
        flushTask = task
        defer { flushTask = nil }
        let acknowledgement = try await task.value
        guard let batch = inFlight,
              acknowledgement?.id == batch.id,
              acknowledgement?.digest == batch.digest else {
            throw BufferedEventRecorderError.acknowledgementMismatch
        }
        inFlight = nil
        if !buckets.isEmpty || !representatives.isEmpty { return acknowledgement }
        return acknowledgement
    }

    public func flushUntilEmpty() async throws {
        while inFlight != nil || !buckets.isEmpty || !representatives.isEmpty {
            _ = try await flush()
        }
    }

    private func makeBatch() -> EventRollupBatch {
        let sortedBuckets = buckets.values.sorted { ($0.bucketStart, $0.source) < ($1.bucketStart, $1.source) }
        let sortedRepresentatives = representatives.values.sorted {
            ($0.timestamp, $0.path, $0.flags) < ($1.timestamp, $1.path, $1.flags)
        }
        let canonical = (try? JSONEncoder.canonical.encode(CanonicalBatch(buckets: sortedBuckets, representatives: sortedRepresentatives))) ?? Data()
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let batch = EventRollupBatch(id: UUID(), digest: digest, buckets: sortedBuckets, representatives: sortedRepresentatives)
        buckets.removeAll(keepingCapacity: true)
        representatives.removeAll(keepingCapacity: true)
        return batch
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

private extension JSONEncoder {
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private enum BufferedEventRecorderError: LocalizedError, Sendable {
    case acknowledgementMismatch
    var errorDescription: String? { "Buffered event recorder received a mismatched acknowledgement." }
}
