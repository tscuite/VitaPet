import CryptoKit
import Foundation

public enum EventRollupDigest {
    private struct CanonicalBatch: Encodable {
        let buckets: [EventRollupBucket]
        let representatives: [FileEventRepresentative]
    }

    public static func calculate(
        buckets: [EventRollupBucket],
        representatives: [FileEventRepresentative]
    ) -> String? {
        let sortedBuckets = buckets.sorted {
            ($0.bucketStart, $0.source, $0.eventCount)
                < ($1.bucketStart, $1.source, $1.eventCount)
        }
        let sortedRepresentatives = representatives.sorted {
            ($0.timestamp, $0.source, $0.path, $0.flags)
                < ($1.timestamp, $1.source, $1.path, $1.flags)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(
            CanonicalBatch(
                buckets: sortedBuckets,
                representatives: sortedRepresentatives
            )
        ) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
