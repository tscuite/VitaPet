import CryptoKit
import Foundation
import SQLite3

extension DatabaseManager {
    public func commitEventRollupBatch(_ batch: EventRollupBatch) throws -> EventBatchAcknowledgement {
        guard batch.formatVersion == 1, !batch.digest.isEmpty else {
            throw EventRollupError.invalidBatch
        }
        guard EventRollupDigest.calculate(
            buckets: batch.buckets,
            representatives: batch.representatives
        ) == batch.digest else {
            throw EventRollupError.digestMismatch
        }
        let database = try getOrOpenDatabase()
        try Self.eventExecute("BEGIN IMMEDIATE;", database: database)
        do {
            if let existing = try Self.eventMarker(id: batch.id, database: database) {
                guard existing == batch.digest else { throw EventRollupError.digestMismatch }
                try Self.eventExecute("COMMIT;", database: database)
                return EventBatchAcknowledgement(id: batch.id, digest: batch.digest)
            }

            let marker = try Self.eventPrepare(
                "INSERT INTO event_rollup_batches(batch_id, digest, format_version, committed_at) VALUES (?, ?, ?, ?);",
                database: database
            )
            defer { sqlite3_finalize(marker) }
            try Self.eventBind(text: batch.id.uuidString, index: 1, statement: marker, database: database)
            try Self.eventBind(text: batch.digest, index: 2, statement: marker, database: database)
            try Self.eventBind(int64: Int64(batch.formatVersion), index: 3, statement: marker, database: database)
            guard sqlite3_bind_double(marker, 4, Date().timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(marker) == SQLITE_DONE else { throw Self.eventSQLiteError(database: database) }

            for bucket in batch.buckets {
                guard bucket.eventCount >= 0 else { throw EventRollupError.invalidBatch }
                let statement = try Self.eventPrepare(
                    "INSERT INTO event_hourly_rollups(bucket_start, source, event_count) VALUES (?, ?, ?) ON CONFLICT(bucket_start, source) DO UPDATE SET event_count = event_hourly_rollups.event_count + excluded.event_count;",
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                try Self.eventBind(int64: bucket.bucketStart, index: 1, statement: statement, database: database)
                try Self.eventBind(text: bucket.source, index: 2, statement: statement, database: database)
                try Self.eventBind(int64: bucket.eventCount, index: 3, statement: statement, database: database)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.eventSQLiteError(database: database) }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for representative in batch.representatives {
                let payload = try encoder.encode(representative)
                let statement = try Self.eventPrepare(
                    "INSERT INTO events(timestamp, source, payload, rollup_accounted) VALUES (datetime(?, 'unixepoch'), ?, ?, 1);",
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                try Self.eventBind(text: String(representative.timestamp), index: 1, statement: statement, database: database)
                try Self.eventBind(text: representative.source, index: 2, statement: statement, database: database)
                try Self.eventBind(data: payload, index: 3, statement: statement, database: database)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.eventSQLiteError(database: database) }
            }

            try Self.eventExecute("COMMIT;", database: database)
            return EventBatchAcknowledgement(id: batch.id, digest: batch.digest)
        } catch {
            let original = String(describing: error)
            do { try Self.eventExecute("ROLLBACK;", database: database) }
            catch { throw EventRollupError.rollbackFailed(original: original, rollback: String(describing: error)) }
            throw error
        }
    }
}

private extension DatabaseManager {
    static func eventMarker(id: UUID, database: OpaquePointer?) throws -> String? {
        let statement = try eventPrepare("SELECT digest FROM event_rollup_batches WHERE batch_id = ?;", database: database)
        defer { sqlite3_finalize(statement) }
        try eventBind(text: id.uuidString, index: 1, statement: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return String(cString: sqlite3_column_text(statement, 0))
        case SQLITE_DONE: return nil
        default: throw eventSQLiteError(database: database)
        }
    }

    static func eventPrepare(_ sql: String, database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw eventSQLiteError(database: database) }
        return statement
    }

    static func eventExecute(_ sql: String, database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw eventSQLiteError(database: database) }
    }

    static func eventBind(text: String, index: Int32, statement: OpaquePointer?, database: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw eventSQLiteError(database: database) }
    }

    static func eventBind(int64: Int64, index: Int32, statement: OpaquePointer?, database: OpaquePointer?) throws {
        guard sqlite3_bind_int64(statement, index, int64) == SQLITE_OK else { throw eventSQLiteError(database: database) }
    }

    static func eventBind(data: Data, index: Int32, statement: OpaquePointer?, database: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        guard result == SQLITE_OK else { throw eventSQLiteError(database: database) }
    }

    static func eventSQLiteError(database: OpaquePointer?) -> EventRollupSQLiteError {
        EventRollupSQLiteError(message: sqlite3_errmsg(database).map(String.init(cString:)) ?? "Unknown SQLite error.")
    }
}

private enum EventRollupError: LocalizedError, Sendable {
    case invalidBatch
    case digestMismatch
    case rollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .invalidBatch: "Invalid event rollup batch."
        case .digestMismatch: "Event rollup batch digest mismatch."
        case let .rollbackFailed(original, rollback): "Event rollup failed (\(original)); rollback failed (\(rollback))."
        }
    }
}

private struct EventRollupSQLiteError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
