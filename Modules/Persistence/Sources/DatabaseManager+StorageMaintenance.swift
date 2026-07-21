import Foundation
import SQLite3

extension DatabaseManager {
    /// Flushes committed WAL frames before the app releases its final database handle.
    public func checkpointForShutdown() throws {
        let database = try getOrOpenDatabase()
        try Self.truncateWAL(database: database)
    }

    public func performStorageMaintenance(
        now: Date = Date(),
        excludingEventRollupBatchID: UUID? = nil
    ) throws -> StorageMaintenanceReport {
        let maintenanceTime = now.timeIntervalSince1970
        guard maintenanceTime.isFinite else {
            throw StorageMaintenanceSQLiteError(message: "Storage-maintenance time is invalid.")
        }

        let detailCutoff = maintenanceTime - StoragePolicy.default.fileDetailRetention
        let retentionCutoff = maintenanceTime - StoragePolicy.default.eventRetention
        let batchMarkerCutoff = maintenanceTime - Self.eventRollupBatchMarkerRetention
        let before = databaseStorageSize()
        let database = try getOrOpenDatabase()
        let runEventIDWatermark = try Self.maximumEventID(database: database)
        let archiveResult = try archiveEligibleConversationTurns(
            hotLimit: StoragePolicy.default.hotTurnsPerSession,
            chunkSize: StoragePolicy.default.archiveChunkSize
        )

        var rolledUpEventCount = 0
        var deletedEventCount = 0
        var deletedRollupCount = 0

        try Self.maintenanceExecute("BEGIN IMMEDIATE;", database: database)
        do {
            let migrationWatermark = try Self.fileEventMigrationWatermark(database: database)
            let legacyEventWatermark = min(migrationWatermark, runEventIDWatermark)
            rolledUpEventCount = try Self.backfillFileChanged(
                detailCutoff: detailCutoff,
                retentionCutoff: retentionCutoff,
                watermark: legacyEventWatermark,
                database: database
            )
            deletedEventCount += try Self.deleteAccountedFileChangedDetails(
                before: detailCutoff,
                eventIDWatermark: runEventIDWatermark,
                database: database
            )
            deletedEventCount += try Self.deleteOrdinaryEvents(
                before: retentionCutoff,
                eventIDWatermark: runEventIDWatermark,
                database: database
            )
            deletedEventCount += try Self.deleteExpiredLegacyFileChangedEvents(
                before: retentionCutoff,
                watermark: legacyEventWatermark,
                database: database
            )
            deletedRollupCount = try Self.deleteExpiredHourlyRollups(
                retentionCutoff: retentionCutoff,
                database: database
            )
            _ = try Self.deleteExpiredEventRollupBatchMarkers(
                before: batchMarkerCutoff,
                excluding: excludingEventRollupBatchID,
                database: database
            )
            try Self.refreshFileEventMigrationCompleteMarker(
                watermark: migrationWatermark,
                database: database
            )
            try Self.maintenanceExecute("COMMIT;", database: database)
        } catch {
            let originalDescription = String(describing: error)
            do {
                try Self.maintenanceExecute("ROLLBACK;", database: database)
            } catch {
                throw StorageMaintenanceSQLiteError(
                    message: "Storage maintenance failed (\(originalDescription)); rollback failed (\(error))."
                )
            }
            throw error
        }

        _ = try promoteOptimizedEventsIndexAfterBoundedMaintenance()
        try Self.truncateWAL(database: database)
        try Self.runBoundedIncrementalVacuumIfEnabled(database: database)

        let after = databaseStorageSize()
        return StorageMaintenanceReport(
            archivedTurnCount: archiveResult.archivedTurnCount,
            rolledUpEventCount: rolledUpEventCount,
            deletedEventCount: deletedEventCount,
            deletedRollupCount: deletedRollupCount,
            reclaimedBytes: max(0, before - after)
        )
    }

    private func databaseStorageSize() -> Int64 {
        let databaseURL = maintenanceDatabaseURL()
        return [databaseURL.path, databaseURL.path + "-wal"].reduce(into: 0) { total, path in
            guard let value = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
                return
            }
            let (next, overflowed) = total.addingReportingOverflow(value.int64Value)
            total = overflowed ? Int64.max : next
        }
    }
}

private extension DatabaseManager {
    static let maintenanceEventBatchLimit = 1_000
    static let maintenanceRollupBatchLimit = 1_000
    static let maintenanceMarkerBatchLimit = 1_000
    static let incrementalVacuumPageLimit: Int64 = 256
    static let eventRollupBatchMarkerRetention: TimeInterval = 7 * 86_400

    struct LegacyFileEventRow {
        let id: Int64
        let timestamp: Int64
    }

    struct HourlyRollupKey {
        let bucketStart: Int64
        let source: String
    }

    enum MaintenanceBinding {
        case int64(Int64)
        case double(Double)
        case text(String)
    }

    enum ExactEventDeletionKind {
        case accountedFileChanged
        case ordinary
        case legacyFileChanged
    }

    static func maximumEventID(database: OpaquePointer?) throws -> Int64 {
        let value = try maintenanceScalarInt(
            "SELECT COALESCE(MAX(id), 0) FROM events;",
            database: database
        )
        guard value >= 0 else {
            throw StorageMaintenanceSQLiteError(message: "Event-ID watermark is invalid.")
        }
        return value
    }

    static func fileEventMigrationWatermark(database: OpaquePointer?) throws -> Int64 {
        let statement = try maintenancePrepare(
            """
            SELECT value
            FROM storage_metadata
            WHERE key = 'file_event_migration_high_watermark';
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let rawValue = sqlite3_column_text(statement, 0),
              let watermark = Int64(String(cString: rawValue)),
              watermark >= 0 else {
            throw StorageMaintenanceSQLiteError(
                message: "File-event migration watermark is missing or invalid."
            )
        }
        return watermark
    }

    static func backfillFileChanged(
        detailCutoff: TimeInterval,
        retentionCutoff: TimeInterval,
        watermark: Int64,
        database: OpaquePointer?
    ) throws -> Int {
        let rows = try selectLegacyFileChangedRows(
            detailCutoff: detailCutoff,
            retentionCutoff: retentionCutoff,
            watermark: watermark,
            database: database
        )

        var buckets: [Int64: Int64] = [:]
        for row in rows {
            let bucketStart = Int64(floor(Double(row.timestamp) / 3_600)) * 3_600
            buckets[bucketStart, default: 0] += 1
        }

        let upsert = try maintenancePrepare(
            """
            INSERT INTO event_hourly_rollups(bucket_start, source, event_count)
            VALUES (?, 'fileChanged', ?)
            ON CONFLICT(bucket_start, source) DO UPDATE SET
                event_count = event_hourly_rollups.event_count + excluded.event_count;
            """,
            database: database
        )
        defer { sqlite3_finalize(upsert) }
        for bucketStart in buckets.keys.sorted() {
            guard let eventCount = buckets[bucketStart] else { continue }
            sqlite3_reset(upsert)
            sqlite3_clear_bindings(upsert)
            try maintenanceBind(int64: bucketStart, index: 1, statement: upsert, database: database)
            try maintenanceBind(int64: eventCount, index: 2, statement: upsert, database: database)
            guard sqlite3_step(upsert) == SQLITE_DONE else {
                throw maintenanceSQLiteError(database: database)
            }
        }

        return try deleteExactEventIDs(
            rows.map(\.id),
            kind: .legacyFileChanged,
            eventIDWatermark: watermark,
            database: database
        )
    }

    static func selectLegacyFileChangedRows(
        detailCutoff: TimeInterval,
        retentionCutoff: TimeInterval,
        watermark: Int64,
        database: OpaquePointer?
    ) throws -> [LegacyFileEventRow] {
        let statement = try maintenancePrepare(
            """
            SELECT id, unixepoch(timestamp)
            FROM events
            WHERE source = 'fileChanged'
              AND rollup_accounted = 0
              AND id <= ?
              AND timestamp >= datetime(?, 'unixepoch')
              AND timestamp < datetime(?, 'unixepoch')
            ORDER BY id
            LIMIT ?;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try maintenanceBind(int64: watermark, index: 1, statement: statement, database: database)
        try maintenanceBind(double: retentionCutoff, index: 2, statement: statement, database: database)
        try maintenanceBind(double: detailCutoff, index: 3, statement: statement, database: database)
        try maintenanceBind(
            int64: Int64(maintenanceEventBatchLimit),
            index: 4,
            statement: statement,
            database: database
        )

        var rows: [LegacyFileEventRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let id = sqlite3_column_int64(statement, 0)
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL else {
                    throw StorageMaintenanceSQLiteError(
                        message: "Legacy file-event row \(id) has an invalid timestamp."
                    )
                }
                rows.append(
                    LegacyFileEventRow(
                        id: id,
                        timestamp: sqlite3_column_int64(statement, 1)
                    )
                )
            case SQLITE_DONE:
                return rows
            default:
                throw maintenanceSQLiteError(database: database)
            }
        }
    }

    static func deleteAccountedFileChangedDetails(
        before cutoff: TimeInterval,
        eventIDWatermark: Int64,
        database: OpaquePointer?
    ) throws -> Int {
        let ids = try selectEventIDs(
            """
            SELECT id
            FROM events
            WHERE source = 'fileChanged'
              AND rollup_accounted = 1
              AND timestamp < datetime(?, 'unixepoch')
              AND id <= ?
            ORDER BY id
            LIMIT ?;
            """,
            bindings: [
                .double(cutoff),
                .int64(eventIDWatermark),
                .int64(Int64(maintenanceEventBatchLimit)),
            ],
            database: database
        )
        return try deleteExactEventIDs(
            ids,
            kind: .accountedFileChanged,
            eventIDWatermark: eventIDWatermark,
            database: database
        )
    }

    static func deleteOrdinaryEvents(
        before cutoff: TimeInterval,
        eventIDWatermark: Int64,
        database: OpaquePointer?
    ) throws -> Int {
        let ids = try selectEventIDs(
            """
            SELECT id
            FROM events
            WHERE source IS NOT 'fileChanged'
              AND timestamp < datetime(?, 'unixepoch')
              AND id <= ?
            ORDER BY id
            LIMIT ?;
            """,
            bindings: [
                .double(cutoff),
                .int64(eventIDWatermark),
                .int64(Int64(maintenanceEventBatchLimit)),
            ],
            database: database
        )
        return try deleteExactEventIDs(
            ids,
            kind: .ordinary,
            eventIDWatermark: eventIDWatermark,
            database: database
        )
    }

    static func deleteExpiredLegacyFileChangedEvents(
        before cutoff: TimeInterval,
        watermark: Int64,
        database: OpaquePointer?
    ) throws -> Int {
        let ids = try selectEventIDs(
            """
            SELECT id
            FROM events
            WHERE source = 'fileChanged'
              AND rollup_accounted = 0
              AND id <= ?
              AND timestamp < datetime(?, 'unixepoch')
            ORDER BY id
            LIMIT ?;
            """,
            bindings: [
                .int64(watermark),
                .double(cutoff),
                .int64(Int64(maintenanceEventBatchLimit)),
            ],
            database: database
        )
        return try deleteExactEventIDs(
            ids,
            kind: .legacyFileChanged,
            eventIDWatermark: watermark,
            database: database
        )
    }

    static func selectEventIDs(
        _ sql: String,
        bindings: [MaintenanceBinding],
        database: OpaquePointer?
    ) throws -> [Int64] {
        let statement = try maintenancePrepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try maintenanceBind(bindings, statement: statement, database: database)

        var ids: [Int64] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                ids.append(sqlite3_column_int64(statement, 0))
            case SQLITE_DONE:
                return ids
            default:
                throw maintenanceSQLiteError(database: database)
            }
        }
    }

    static func deleteExactEventIDs(
        _ ids: [Int64],
        kind: ExactEventDeletionKind,
        eventIDWatermark: Int64,
        database: OpaquePointer?
    ) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let sql: String
        switch kind {
        case .accountedFileChanged:
            sql = """
            DELETE FROM events
            WHERE id = ? AND id <= ?
              AND source = 'fileChanged'
              AND rollup_accounted = 1;
            """
        case .ordinary:
            sql = """
            DELETE FROM events
            WHERE id = ? AND id <= ?
              AND source IS NOT 'fileChanged';
            """
        case .legacyFileChanged:
            sql = """
            DELETE FROM events
            WHERE id = ? AND id <= ?
              AND source = 'fileChanged'
              AND rollup_accounted = 0;
            """
        }
        let statement = try maintenancePrepare(
            sql,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        var deleted = 0
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try maintenanceBind(int64: id, index: 1, statement: statement, database: database)
            try maintenanceBind(
                int64: eventIDWatermark,
                index: 2,
                statement: statement,
                database: database
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw maintenanceSQLiteError(database: database)
            }
            guard sqlite3_changes(database) == 1 else {
                throw StorageMaintenanceSQLiteError(
                    message: "Event row \(id) changed during maintenance."
                )
            }
            deleted += 1
        }
        return deleted
    }

    static func deleteExpiredHourlyRollups(
        retentionCutoff: TimeInterval,
        database: OpaquePointer?
    ) throws -> Int {
        let select = try maintenancePrepare(
            """
            SELECT bucket_start, source
            FROM event_hourly_rollups
            WHERE bucket_start <= ?
            ORDER BY bucket_start, source
            LIMIT ?;
            """,
            database: database
        )
        defer { sqlite3_finalize(select) }
        try maintenanceBind(
            double: retentionCutoff - 3_600,
            index: 1,
            statement: select,
            database: database
        )
        try maintenanceBind(
            int64: Int64(maintenanceRollupBatchLimit),
            index: 2,
            statement: select,
            database: database
        )

        var keys: [HourlyRollupKey] = []
        selectLoop: while true {
            switch sqlite3_step(select) {
            case SQLITE_ROW:
                guard let rawSource = sqlite3_column_text(select, 1) else {
                    throw StorageMaintenanceSQLiteError(message: "Hourly rollup has a NULL source.")
                }
                keys.append(
                    HourlyRollupKey(
                        bucketStart: sqlite3_column_int64(select, 0),
                        source: String(cString: rawSource)
                    )
                )
            case SQLITE_DONE:
                break selectLoop
            default:
                throw maintenanceSQLiteError(database: database)
            }
        }

        guard !keys.isEmpty else { return 0 }
        let delete = try maintenancePrepare(
            "DELETE FROM event_hourly_rollups WHERE bucket_start = ? AND source = ?;",
            database: database
        )
        defer { sqlite3_finalize(delete) }
        var deleted = 0
        for key in keys {
            sqlite3_reset(delete)
            sqlite3_clear_bindings(delete)
            try maintenanceBind(int64: key.bucketStart, index: 1, statement: delete, database: database)
            try maintenanceBind(text: key.source, index: 2, statement: delete, database: database)
            guard sqlite3_step(delete) == SQLITE_DONE else {
                throw maintenanceSQLiteError(database: database)
            }
            guard sqlite3_changes(database) == 1 else {
                throw StorageMaintenanceSQLiteError(
                    message: "Hourly rollup changed during maintenance."
                )
            }
            deleted += 1
        }
        return deleted
    }

    static func deleteExpiredEventRollupBatchMarkers(
        before cutoff: TimeInterval,
        excluding excludedID: UUID?,
        database: OpaquePointer?
    ) throws -> Int {
        let sql: String
        var bindings: [MaintenanceBinding] = [.double(cutoff)]
        if let excludedID {
            sql = """
            SELECT batch_id
            FROM event_rollup_batches
            WHERE committed_at < ?
              AND batch_id <> ?
            ORDER BY committed_at, batch_id
            LIMIT ?;
            """
            bindings.append(.text(excludedID.uuidString))
        } else {
            sql = """
            SELECT batch_id
            FROM event_rollup_batches
            WHERE committed_at < ?
            ORDER BY committed_at, batch_id
            LIMIT ?;
            """
        }
        bindings.append(.int64(Int64(maintenanceMarkerBatchLimit)))

        let select = try maintenancePrepare(sql, database: database)
        defer { sqlite3_finalize(select) }
        try maintenanceBind(bindings, statement: select, database: database)
        var batchIDs: [String] = []
        selectLoop: while true {
            switch sqlite3_step(select) {
            case SQLITE_ROW:
                guard let rawID = sqlite3_column_text(select, 0) else {
                    throw StorageMaintenanceSQLiteError(message: "Event-rollup batch marker has a NULL ID.")
                }
                batchIDs.append(String(cString: rawID))
            case SQLITE_DONE:
                break selectLoop
            default:
                throw maintenanceSQLiteError(database: database)
            }
        }

        guard !batchIDs.isEmpty else { return 0 }
        let delete = try maintenancePrepare(
            "DELETE FROM event_rollup_batches WHERE batch_id = ?;",
            database: database
        )
        defer { sqlite3_finalize(delete) }
        var deleted = 0
        for batchID in batchIDs {
            sqlite3_reset(delete)
            sqlite3_clear_bindings(delete)
            try maintenanceBind(text: batchID, index: 1, statement: delete, database: database)
            guard sqlite3_step(delete) == SQLITE_DONE else {
                throw maintenanceSQLiteError(database: database)
            }
            guard sqlite3_changes(database) == 1 else {
                throw StorageMaintenanceSQLiteError(
                    message: "Event-rollup batch marker changed during maintenance."
                )
            }
            deleted += 1
        }
        return deleted
    }

    static func refreshFileEventMigrationCompleteMarker(
        watermark: Int64,
        database: OpaquePointer?
    ) throws {
        let hasPendingLegacyRows: Bool
        do {
            let statement = try maintenancePrepare(
                """
                SELECT EXISTS(
                    SELECT 1
                    FROM events
                    WHERE source = 'fileChanged'
                      AND rollup_accounted = 0
                      AND id <= ?
                );
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try maintenanceBind(int64: watermark, index: 1, statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw maintenanceSQLiteError(database: database)
            }
            hasPendingLegacyRows = sqlite3_column_int64(statement, 0) != 0
        }

        if !hasPendingLegacyRows {
            try maintenanceExecute(
                """
                INSERT INTO storage_metadata(key, value)
                VALUES ('file_event_migration_complete', '1')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """,
                database: database
            )
        } else {
            try maintenanceExecute(
                "DELETE FROM storage_metadata WHERE key = 'file_event_migration_complete';",
                database: database
            )
        }
    }

    static func truncateWAL(database: OpaquePointer?) throws {
        var logFrameCount: Int32 = 0
        var checkpointedFrameCount: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrameCount,
            &checkpointedFrameCount
        )
        guard result == SQLITE_OK else {
            throw StorageMaintenanceSQLiteError(
                message: "TRUNCATE WAL checkpoint failed with SQLite result \(result)."
            )
        }
    }

    static func runBoundedIncrementalVacuumIfEnabled(database: OpaquePointer?) throws {
        guard try maintenanceScalarInt("PRAGMA auto_vacuum;", database: database) == 2 else {
            return
        }
        let freePages = try maintenanceScalarInt("PRAGMA freelist_count;", database: database)
        let pages = max(0, min(incrementalVacuumPageLimit, freePages))
        guard pages > 0 else { return }
        try maintenanceExecute("PRAGMA incremental_vacuum(\(pages));", database: database)
    }

    static func maintenanceScalarInt(
        _ sql: String,
        database: OpaquePointer?
    ) throws -> Int64 {
        let statement = try maintenancePrepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw maintenanceSQLiteError(database: database)
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func maintenancePrepare(
        _ sql: String,
        database: OpaquePointer?
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw maintenanceSQLiteError(database: database)
        }
        return statement
    }

    static func maintenanceExecute(_ sql: String, database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw maintenanceSQLiteError(database: database)
        }
    }

    static func maintenanceBind(
        _ bindings: [MaintenanceBinding],
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case let .int64(value):
                try maintenanceBind(
                    int64: value,
                    index: index,
                    statement: statement,
                    database: database
                )
            case let .double(value):
                try maintenanceBind(
                    double: value,
                    index: index,
                    statement: statement,
                    database: database
                )
            case let .text(value):
                try maintenanceBind(
                    text: value,
                    index: index,
                    statement: statement,
                    database: database
                )
            }
        }
    }

    static func maintenanceBind(
        text: String,
        index: Int32,
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else {
            throw maintenanceSQLiteError(database: database)
        }
    }

    static func maintenanceBind(
        int64: Int64,
        index: Int32,
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        guard sqlite3_bind_int64(statement, index, int64) == SQLITE_OK else {
            throw maintenanceSQLiteError(database: database)
        }
    }

    static func maintenanceBind(
        double: Double,
        index: Int32,
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        guard sqlite3_bind_double(statement, index, double) == SQLITE_OK else {
            throw maintenanceSQLiteError(database: database)
        }
    }

    static func maintenanceSQLiteError(database: OpaquePointer?) -> StorageMaintenanceSQLiteError {
        StorageMaintenanceSQLiteError(
            message: sqlite3_errmsg(database).map(String.init(cString:)) ?? "SQLite error"
        )
    }
}

private struct StorageMaintenanceSQLiteError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
