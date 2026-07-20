import Foundation

public struct StoragePolicy: Sendable, Equatable {
    public let hotTurnsPerSession: Int
    public let archiveChunkSize: Int
    public let fileDetailRetention: TimeInterval
    public let eventRetention: TimeInterval
    public let flushInterval: TimeInterval
    public let maintenanceInterval: TimeInterval
    public let fullCompactionMinimumBytes: Int64
    public let fullCompactionFreeRatio: Double
    public let compactionSafetyBytes: Int64

    public init(
        hotTurnsPerSession: Int,
        archiveChunkSize: Int,
        fileDetailRetention: TimeInterval,
        eventRetention: TimeInterval,
        flushInterval: TimeInterval,
        maintenanceInterval: TimeInterval,
        fullCompactionMinimumBytes: Int64,
        fullCompactionFreeRatio: Double,
        compactionSafetyBytes: Int64
    ) {
        self.hotTurnsPerSession = hotTurnsPerSession
        self.archiveChunkSize = archiveChunkSize
        self.fileDetailRetention = fileDetailRetention
        self.eventRetention = eventRetention
        self.flushInterval = flushInterval
        self.maintenanceInterval = maintenanceInterval
        self.fullCompactionMinimumBytes = fullCompactionMinimumBytes
        self.fullCompactionFreeRatio = fullCompactionFreeRatio
        self.compactionSafetyBytes = compactionSafetyBytes
    }

    public static let `default` = StoragePolicy(
        hotTurnsPerSession: 500,
        archiveChunkSize: 250,
        fileDetailRetention: 86_400,
        eventRetention: 2_592_000,
        flushInterval: 30,
        maintenanceInterval: 86_400,
        fullCompactionMinimumBytes: 256 << 20,
        fullCompactionFreeRatio: 0.25,
        compactionSafetyBytes: 256 << 20
    )

    public func shouldFullyCompact(
        databaseBytes: Int64,
        freePages: Int64,
        pageCount: Int64,
        availableBytes: Int64,
        walBytes: Int64
    ) -> Bool {
        guard databaseBytes >= 0,
              databaseBytes >= fullCompactionMinimumBytes,
              walBytes >= 0,
              availableBytes >= 0,
              pageCount > 0,
              freePages >= 0,
              freePages <= pageCount,
              fullCompactionMinimumBytes >= 0,
              compactionSafetyBytes >= 0,
              fullCompactionFreeRatio.isFinite,
              fullCompactionFreeRatio >= 0,
              fullCompactionFreeRatio <= 1,
              Double(freePages) / Double(pageCount) >= fullCompactionFreeRatio else {
            return false
        }

        let (databaseAndWALBytes, additionOverflowed) = databaseBytes.addingReportingOverflow(walBytes)
        guard !additionOverflowed else { return false }

        let (temporaryCopyBytes, multiplicationOverflowed) = databaseAndWALBytes.multipliedReportingOverflow(by: 2)
        guard !multiplicationOverflowed else { return false }

        let (requiredBytes, safetyAdditionOverflowed) = temporaryCopyBytes.addingReportingOverflow(compactionSafetyBytes)
        guard !safetyAdditionOverflowed else { return false }

        return availableBytes >= requiredBytes
    }
}
