import Persistence
import XCTest

final class StoragePolicyTests: XCTestCase {
    private let mebibyte: Int64 = 1 << 20

    func testDefaultPolicyMatchesStorageLifecycleLimits() {
        let policy = StoragePolicy.default

        XCTAssertEqual(policy.hotTurnsPerSession, 500)
        XCTAssertEqual(policy.archiveChunkSize, 250)
        XCTAssertEqual(policy.fileDetailRetention, 86_400)
        XCTAssertEqual(policy.eventRetention, 2_592_000)
        XCTAssertEqual(policy.flushInterval, 30)
        XCTAssertEqual(policy.maintenanceInterval, 86_400)
        XCTAssertEqual(policy.fullCompactionMinimumBytes, 256 * mebibyte)
        XCTAssertEqual(policy.fullCompactionFreeRatio, 0.25)
        XCTAssertEqual(policy.compactionSafetyBytes, 256 * mebibyte)
        XCTAssertEqual(policy, .default)
        requireSendable(policy)
    }

    func testFullCompactionRequiresDatabaseAndFreelistThresholds() {
        let policy = StoragePolicy.default
        let ampleCapacity = Int64.max

        XCTAssertFalse(
            policy.shouldFullyCompact(
                databaseBytes: (256 * mebibyte) - 1,
                freePages: 25,
                pageCount: 100,
                availableBytes: ampleCapacity,
                walBytes: 0
            )
        )
        XCTAssertFalse(
            policy.shouldFullyCompact(
                databaseBytes: 300 * mebibyte,
                freePages: 24,
                pageCount: 100,
                availableBytes: ampleCapacity,
                walBytes: 0
            )
        )
        XCTAssertFalse(
            policy.shouldFullyCompact(
                databaseBytes: 300 * mebibyte,
                freePages: 1,
                pageCount: 0,
                availableBytes: ampleCapacity,
                walBytes: 0
            )
        )
        XCTAssertTrue(
            policy.shouldFullyCompact(
                databaseBytes: 256 * mebibyte,
                freePages: 25,
                pageCount: 100,
                availableBytes: (2 * 256 * mebibyte) + (256 * mebibyte),
                walBytes: 0
            )
        )
    }

    func testFullCompactionCapacityIncludesDatabaseWALAndSafetyMargin() {
        let policy = StoragePolicy.default
        let databaseBytes = 300 * mebibyte
        let walBytes = 20 * mebibyte
        let requiredCapacity = (2 * (databaseBytes + walBytes)) + policy.compactionSafetyBytes

        XCTAssertFalse(
            policy.shouldFullyCompact(
                databaseBytes: databaseBytes,
                freePages: 30,
                pageCount: 100,
                availableBytes: requiredCapacity - 1,
                walBytes: walBytes
            )
        )
        XCTAssertTrue(
            policy.shouldFullyCompact(
                databaseBytes: databaseBytes,
                freePages: 30,
                pageCount: 100,
                availableBytes: requiredCapacity,
                walBytes: walBytes
            )
        )
        XCTAssertFalse(
            policy.shouldFullyCompact(
                databaseBytes: Int64.max,
                freePages: 30,
                pageCount: 100,
                availableBytes: Int64.max,
                walBytes: 1
            )
        )
    }

    func testStorageReadinessAndFeatureGatesAreSendableValues() {
        let readiness = StorageSchemaReadiness(
            coreReady: true,
            optimized: false,
            degradedReason: "optimized index deferred"
        )
        let gates = StorageFeatureGates(
            retentionEnabled: true,
            fullCompactionEnabled: false,
            schedulerEnabled: true
        )

        XCTAssertEqual(
            readiness,
            StorageSchemaReadiness(
                coreReady: true,
                optimized: false,
                degradedReason: "optimized index deferred"
            )
        )
        XCTAssertEqual(
            gates,
            StorageFeatureGates(
                retentionEnabled: true,
                fullCompactionEnabled: false,
                schedulerEnabled: true
            )
        )
        requireSendable(readiness)
        requireSendable(gates)
    }

    private func requireSendable<T: Sendable>(_: T) {}
}
