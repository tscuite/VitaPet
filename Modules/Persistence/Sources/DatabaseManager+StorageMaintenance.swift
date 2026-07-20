import Foundation
import SQLite3

extension DatabaseManager {
    public func performStorageMaintenance(now: Date = Date()) throws -> StorageMaintenanceReport {
        let before = try databaseFileSize()
        let archiveResult = try archiveEligibleConversationTurns(hotLimit: StoragePolicy.default.hotTurnsPerSession, chunkSize: StoragePolicy.default.archiveChunkSize)
        let database = try getOrOpenDatabase()
        let detailCutoff = now.timeIntervalSince1970 - StoragePolicy.default.fileDetailRetention
        let retentionCutoff = now.timeIntervalSince1970 - StoragePolicy.default.eventRetention
        try Self.maintenanceExecute("BEGIN IMMEDIATE;", database: database)
        do {
            let rolled = try Self.backfillFileChanged(cutoff: detailCutoff, retentionCutoff: retentionCutoff, database: database)
            let deletedDetail = try Self.maintenanceDelete(
                "DELETE FROM events WHERE timestamp < datetime(?, 'unixepoch') AND (source <> 'fileChanged' OR rollup_accounted = 1);",
                value: String(detailCutoff), database: database
            )
            let deletedExpired = try Self.maintenanceDelete(
                "DELETE FROM events WHERE timestamp < datetime(?, 'unixepoch') AND source = 'fileChanged';",
                value: String(retentionCutoff), database: database
            )
            let deletedRollups = try Self.maintenanceDelete(
                "DELETE FROM event_hourly_rollups WHERE bucket_start < ?;",
                value: String(Int64(floor(retentionCutoff / 3_600) * 3_600)), database: database
            )
            try Self.maintenanceExecute("COMMIT;", database: database)
            sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            let after = try databaseFileSize()
            return StorageMaintenanceReport(
                archivedTurnCount: archiveResult.archivedTurnCount,
                rolledUpEventCount: rolled,
                deletedEventCount: deletedDetail + deletedExpired,
                deletedRollupCount: deletedRollups,
                reclaimedBytes: max(0, before - after)
            )
        } catch {
            try? Self.maintenanceExecute("ROLLBACK;", database: database)
            throw error
        }
    }

    private func databaseFileSize() throws -> Int64 {
        let url = maintenanceDatabaseURL()
        return Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
}

private extension DatabaseManager {
    static func backfillFileChanged(cutoff: TimeInterval, retentionCutoff: TimeInterval, database: OpaquePointer?) throws -> Int {
        let select = try maintenancePrepare("SELECT id, timestamp FROM events WHERE source='fileChanged' AND rollup_accounted=0 AND timestamp >= datetime(?, 'unixepoch') AND timestamp < datetime(?, 'unixepoch') LIMIT 1000;", database: database)
        defer { sqlite3_finalize(select) }
        try maintenanceBind(text: String(retentionCutoff), index: 1, statement: select, database: database)
        try maintenanceBind(text: String(cutoff), index: 2, statement: select, database: database)
        var ids: [Int64] = []
        var buckets: [Int64: Int64] = [:]
        while sqlite3_step(select) == SQLITE_ROW {
            let id = sqlite3_column_int64(select, 0)
            let timestamp = sqlite3_column_text(select, 1).map { Double(String(cString: $0)) ?? 0 } ?? 0
            ids.append(id)
            let bucket = Int64(floor(timestamp / 3_600) * 3_600)
            buckets[bucket, default: 0] += 1
        }
        for (bucket, count) in buckets {
            let statement = try maintenancePrepare("INSERT INTO event_hourly_rollups(bucket_start, source, event_count) VALUES (?, 'fileChanged', ?) ON CONFLICT(bucket_start, source) DO UPDATE SET event_count = event_hourly_rollups.event_count + excluded.event_count;", database: database)
            defer { sqlite3_finalize(statement) }
            try maintenanceBind(int64: bucket, index: 1, statement: statement, database: database)
            try maintenanceBind(int64: count, index: 2, statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw maintenanceSQLiteError(database: database) }
        }
        for id in ids {
            let statement = try maintenancePrepare("DELETE FROM events WHERE id=? AND source='fileChanged' AND rollup_accounted=0;", database: database)
            defer { sqlite3_finalize(statement) }
            try maintenanceBind(int64: id, index: 1, statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw maintenanceSQLiteError(database: database) }
        }
        return ids.count
    }

    static func maintenanceDelete(_ sql: String, value: String, database: OpaquePointer?) throws -> Int {
        let statement = try maintenancePrepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try maintenanceBind(text: value, index: 1, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw maintenanceSQLiteError(database: database) }
        return Int(sqlite3_changes(database))
    }

    static func maintenancePrepare(_ sql: String, database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw maintenanceSQLiteError(database: database) }
        return statement
    }
    static func maintenanceExecute(_ sql: String, database: OpaquePointer?) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw maintenanceSQLiteError(database: database) } }
    static func maintenanceBind(text: String, index: Int32, statement: OpaquePointer?, database: OpaquePointer?) throws { let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self); guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw maintenanceSQLiteError(database: database) } }
    static func maintenanceBind(int64: Int64, index: Int32, statement: OpaquePointer?, database: OpaquePointer?) throws { guard sqlite3_bind_int64(statement, index, int64) == SQLITE_OK else { throw maintenanceSQLiteError(database: database) } }
    static func maintenanceSQLiteError(database: OpaquePointer?) -> StorageMaintenanceSQLiteError { StorageMaintenanceSQLiteError(message: sqlite3_errmsg(database).map(String.init(cString:)) ?? "SQLite error") }
}

private struct StorageMaintenanceSQLiteError: LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }
