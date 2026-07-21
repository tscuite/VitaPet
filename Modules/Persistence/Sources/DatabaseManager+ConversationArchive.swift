import Foundation
import SQLite3

extension DatabaseManager {
    @discardableResult
    public func archiveEligibleConversationTurns(
        hotLimit: Int,
        chunkSize: Int
    ) throws -> ConversationArchiveResult {
        guard hotLimit >= 0 else {
            throw ConversationArchiveStoreError.invalidHotLimit
        }
        guard (1...250).contains(chunkSize) else {
            throw ConversationArchiveStoreError.invalidChunkSize
        }

        let database = try getOrOpenDatabase()
        var createdArchiveCount = 0
        var archivedTurnCount = 0

        while true {
            try Task.checkCancellation()
            guard let outcome = try Self.archiveNextEligibleChunk(
                hotLimit: hotLimit,
                chunkSize: chunkSize,
                database: database
            ) else {
                return ConversationArchiveResult(
                    createdArchiveCount: createdArchiveCount,
                    archivedTurnCount: archivedTurnCount
                )
            }
            if outcome.createdArchive {
                createdArchiveCount += 1
            }
            archivedTurnCount += outcome.archivedTurnCount
        }
    }

    public func listConversationArchives(
        sessionId: String? = nil
    ) throws -> [ConversationArchiveRecord] {
        let database = try getOrOpenDatabase()
        let sql: String
        if sessionId == nil {
            sql = """
            SELECT archive_id, session_id, first_turn_id, last_turn_id,
                   membership_digest, turn_count, codec, format_version,
                   compressed_payload, uncompressed_bytes, payload_checksum, created_at
            FROM conversation_archives
            ORDER BY session_id COLLATE BINARY, first_turn_id, last_turn_id, archive_id;
            """
        } else {
            sql = """
            SELECT archive_id, session_id, first_turn_id, last_turn_id,
                   membership_digest, turn_count, codec, format_version,
                   compressed_payload, uncompressed_bytes, payload_checksum, created_at
            FROM conversation_archives
            WHERE session_id = ?
            ORDER BY first_turn_id, last_turn_id, archive_id;
            """
        }

        let statement = try Self.archivePrepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        if let sessionId {
            try Self.archiveBind(text: sessionId, index: 1, statement: statement, database: database)
        }
        return try Self.archiveReadRecords(statement: statement, database: database)
    }

    public func conversationArchiveCount(sessionId: String? = nil) throws -> Int {
        let database = try getOrOpenDatabase()
        let sql = sessionId == nil
            ? "SELECT COUNT(*) FROM conversation_archives;"
            : "SELECT COUNT(*) FROM conversation_archives WHERE session_id = ?;"
        let statement = try Self.archivePrepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        if let sessionId {
            try Self.archiveBind(text: sessionId, index: 1, statement: statement, database: database)
        }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let count = Int(exactly: sqlite3_column_int64(statement, 0)) else {
            throw ConversationArchiveStoreError.invalidCandidate
        }
        return count
    }

    public func decodeConversationArchive(
        archiveID: String
    ) throws -> [ArchivedConversationTurn] {
        let database = try getOrOpenDatabase()
        guard let record = try Self.archiveRecord(
            archiveID: archiveID,
            database: database
        ) else {
            throw ConversationArchiveStoreError.archiveNotFound
        }
        return try ConversationArchiveCodec.decode(record)
    }

    public func clearConversation() async throws {
        let database = try getOrOpenDatabase()
        try Self.archiveTransaction(database: database) {
            try Self.archiveExecute("DELETE FROM conversation_archives;", database: database)
            try Self.archiveExecute("DELETE FROM conversation_turns;", database: database)
        }
    }

    public func deleteConversation(id: String) async throws {
        let database = try getOrOpenDatabase()
        try Self.archiveTransaction(database: database) {
            try Self.archiveDeleteRows(
                table: "conversation_archives",
                column: "session_id",
                value: id,
                database: database
            )
            try Self.archiveDeleteRows(
                table: "conversation_turns",
                column: "session_id",
                value: id,
                database: database
            )
            try Self.archiveDeleteRows(
                table: "conversations",
                column: "id",
                value: id,
                database: database
            )
        }
    }
}

private extension DatabaseManager {
    struct ArchiveChunkOutcome {
        let createdArchive: Bool
        let archivedTurnCount: Int
    }

    static func archiveNextEligibleChunk(
        hotLimit: Int,
        chunkSize: Int,
        database: OpaquePointer?
    ) throws -> ArchiveChunkOutcome? {
        try archiveExecute("BEGIN IMMEDIATE;", database: database)
        do {
            guard let candidate = try archiveCandidateSession(
                hotLimit: hotLimit,
                database: database
            ) else {
                try archiveExecute("COMMIT;", database: database)
                return nil
            }

            let eligibleCount = candidate.turnCount - hotLimit
            guard eligibleCount > 0 else {
                throw ConversationArchiveStoreError.invalidCandidate
            }
            let turns = try archiveOldestTurns(
                sessionID: candidate.sessionID,
                limit: min(eligibleCount, chunkSize),
                database: database
            )
            guard !turns.isEmpty else {
                throw ConversationArchiveStoreError.invalidCandidate
            }

            let encoded = try ConversationArchiveCodec.encode(turns)
            let overlapping = try archiveOverlappingRecords(
                sessionID: encoded.sessionID,
                firstTurnID: encoded.firstTurnID,
                lastTurnID: encoded.lastTurnID,
                database: database
            )
            for record in overlapping where !archiveRecord(record, matches: encoded) {
                throw ConversationArchiveStoreError.overlappingArchive
            }
            if overlapping.count > 1 {
                throw ConversationArchiveStoreError.overlappingArchive
            }

            let created = try archiveInsertIfAbsent(encoded, database: database)
            guard let stored = try archiveRecord(
                archiveID: encoded.archiveID,
                database: database
            ), archiveRecord(stored, matches: encoded) else {
                throw ConversationArchiveStoreError.storedArchiveMismatch
            }

            let decodedTurns = try ConversationArchiveCodec.decode(stored)
            guard archiveTurnsExactlyEqual(decodedTurns, turns) else {
                throw ConversationArchiveStoreError.storedArchiveMismatch
            }

            let sourceIDs = turns.map(\.id)
            let currentTurns = try archiveTurns(
                sessionID: encoded.sessionID,
                exactIDs: sourceIDs,
                database: database
            )
            guard archiveTurnsExactlyEqual(currentTurns, turns) else {
                throw ConversationArchiveStoreError.sourceRowsChanged
            }

            try Task.checkCancellation()
            try archiveDeleteTurns(
                sessionID: encoded.sessionID,
                exactIDs: sourceIDs,
                database: database
            )
            guard sqlite3_changes(database) == Int32(turns.count) else {
                throw ConversationArchiveStoreError.affectedRowCountMismatch
            }

            try archiveExecute("COMMIT;", database: database)
            return ArchiveChunkOutcome(
                createdArchive: created,
                archivedTurnCount: turns.count
            )
        } catch {
            let original = String(describing: error)
            do {
                try archiveExecute("ROLLBACK;", database: database)
            } catch {
                throw ConversationArchiveStoreError.rollbackFailed(
                    original: original,
                    rollback: String(describing: error)
                )
            }
            throw error
        }
    }

    static func archiveCandidateSession(
        hotLimit: Int,
        database: OpaquePointer?
    ) throws -> (sessionID: String, turnCount: Int)? {
        let statement = try archivePrepare(
            """
            SELECT session_id, COUNT(*)
            FROM conversation_turns
            GROUP BY session_id
            HAVING COUNT(*) > ?
            ORDER BY session_id COLLATE BINARY
            LIMIT 1;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(int64: Int64(hotLimit), index: 1, statement: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let count64 = sqlite3_column_int64(statement, 1)
            guard let count = Int(exactly: count64) else {
                throw ConversationArchiveStoreError.invalidCandidate
            }
            return (archiveColumnText(index: 0, statement: statement), count)
        case SQLITE_DONE:
            return nil
        default:
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveOldestTurns(
        sessionID: String,
        limit: Int,
        database: OpaquePointer?
    ) throws -> [ArchivedConversationTurn] {
        let statement = try archivePrepare(
            """
            SELECT id, role, content, timestamp, session_id, pet_id, pet_name
            FROM conversation_turns
            WHERE session_id = ?
            ORDER BY id ASC
            LIMIT ?;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(text: sessionID, index: 1, statement: statement, database: database)
        try archiveBind(int64: Int64(limit), index: 2, statement: statement, database: database)
        return try archiveReadTurns(statement: statement, database: database)
    }

    static func archiveTurns(
        sessionID: String,
        exactIDs: [Int64],
        database: OpaquePointer?
    ) throws -> [ArchivedConversationTurn] {
        guard !exactIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: exactIDs.count).joined(separator: ",")
        let statement = try archivePrepare(
            """
            SELECT id, role, content, timestamp, session_id, pet_id, pet_name
            FROM conversation_turns
            WHERE session_id = ? AND id IN (\(placeholders))
            ORDER BY id ASC;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(text: sessionID, index: 1, statement: statement, database: database)
        for (offset, id) in exactIDs.enumerated() {
            try archiveBind(
                int64: id,
                index: Int32(offset + 2),
                statement: statement,
                database: database
            )
        }
        return try archiveReadTurns(statement: statement, database: database)
    }

    static func archiveReadTurns(
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws -> [ArchivedConversationTurn] {
        var turns: [ArchivedConversationTurn] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                turns.append(
                    ArchivedConversationTurn(
                        id: sqlite3_column_int64(statement, 0),
                        role: archiveColumnText(index: 1, statement: statement),
                        content: archiveColumnText(index: 2, statement: statement),
                        timestamp: sqlite3_column_double(statement, 3),
                        sessionID: archiveColumnText(index: 4, statement: statement),
                        petID: archiveOptionalColumnText(index: 5, statement: statement),
                        petName: archiveOptionalColumnText(index: 6, statement: statement)
                    )
                )
            case SQLITE_DONE:
                return turns
            default:
                throw archiveSQLiteError(database: database)
            }
        }
    }

    static func archiveOverlappingRecords(
        sessionID: String,
        firstTurnID: Int64,
        lastTurnID: Int64,
        database: OpaquePointer?
    ) throws -> [ConversationArchiveRecord] {
        let statement = try archivePrepare(
            """
            SELECT archive_id, session_id, first_turn_id, last_turn_id,
                   membership_digest, turn_count, codec, format_version,
                   compressed_payload, uncompressed_bytes, payload_checksum, created_at
            FROM conversation_archives
            WHERE session_id = ? AND first_turn_id <= ? AND last_turn_id >= ?
            ORDER BY first_turn_id, last_turn_id, archive_id;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(text: sessionID, index: 1, statement: statement, database: database)
        try archiveBind(int64: lastTurnID, index: 2, statement: statement, database: database)
        try archiveBind(int64: firstTurnID, index: 3, statement: statement, database: database)
        return try archiveReadRecords(statement: statement, database: database)
    }

    static func archiveInsertIfAbsent(
        _ archive: EncodedConversationArchive,
        database: OpaquePointer?
    ) throws -> Bool {
        let statement = try archivePrepare(
            """
            INSERT INTO conversation_archives(
                archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                payload_checksum, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(archive_id) DO NOTHING;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(text: archive.archiveID, index: 1, statement: statement, database: database)
        try archiveBind(text: archive.sessionID, index: 2, statement: statement, database: database)
        try archiveBind(int64: archive.firstTurnID, index: 3, statement: statement, database: database)
        try archiveBind(int64: archive.lastTurnID, index: 4, statement: statement, database: database)
        try archiveBind(text: archive.membershipDigest, index: 5, statement: statement, database: database)
        try archiveBind(int64: Int64(archive.turnCount), index: 6, statement: statement, database: database)
        try archiveBind(text: archive.codec, index: 7, statement: statement, database: database)
        try archiveBind(int64: Int64(archive.formatVersion), index: 8, statement: statement, database: database)
        try archiveBind(data: archive.compressedPayload, index: 9, statement: statement, database: database)
        try archiveBind(int64: Int64(archive.uncompressedBytes), index: 10, statement: statement, database: database)
        try archiveBind(text: archive.payloadChecksum, index: 11, statement: statement, database: database)
        guard sqlite3_bind_double(statement, 12, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw archiveSQLiteError(database: database)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw archiveSQLiteError(database: database)
        }
        return sqlite3_changes(database) == 1
    }

    static func archiveRecord(
        archiveID: String,
        database: OpaquePointer?
    ) throws -> ConversationArchiveRecord? {
        let statement = try archivePrepare(
            """
            SELECT archive_id, session_id, first_turn_id, last_turn_id,
                   membership_digest, turn_count, codec, format_version,
                   compressed_payload, uncompressed_bytes, payload_checksum, created_at
            FROM conversation_archives
            WHERE archive_id = ?;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(text: archiveID, index: 1, statement: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try archiveReadRecord(statement: statement, database: database)
        case SQLITE_DONE:
            return nil
        default:
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveReadRecords(
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws -> [ConversationArchiveRecord] {
        var records: [ConversationArchiveRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try archiveReadRecord(statement: statement, database: database))
            case SQLITE_DONE:
                return records
            default:
                throw archiveSQLiteError(database: database)
            }
        }
    }

    static func archiveReadRecord(
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws -> ConversationArchiveRecord {
        let turnCount64 = sqlite3_column_int64(statement, 5)
        let uncompressedBytes64 = sqlite3_column_int64(statement, 9)
        guard let turnCount = Int(exactly: turnCount64),
              let formatVersion = Int(exactly: sqlite3_column_int64(statement, 7)),
              let uncompressedBytes = Int(exactly: uncompressedBytes64),
              let compressedPayload = archiveColumnData(index: 8, statement: statement) else {
            throw ConversationArchiveStoreError.invalidStoredRecord
        }
        return ConversationArchiveRecord(
            archiveID: archiveColumnText(index: 0, statement: statement),
            sessionID: archiveColumnText(index: 1, statement: statement),
            firstTurnID: sqlite3_column_int64(statement, 2),
            lastTurnID: sqlite3_column_int64(statement, 3),
            membershipDigest: archiveColumnText(index: 4, statement: statement),
            turnCount: turnCount,
            codec: archiveColumnText(index: 6, statement: statement),
            formatVersion: formatVersion,
            compressedPayload: compressedPayload,
            uncompressedBytes: uncompressedBytes,
            payloadChecksum: archiveColumnText(index: 10, statement: statement),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
        )
    }

    static func archiveRecord(
        _ record: ConversationArchiveRecord,
        matches archive: EncodedConversationArchive
    ) -> Bool {
        record.archiveID == archive.archiveID
            && record.sessionID == archive.sessionID
            && record.firstTurnID == archive.firstTurnID
            && record.lastTurnID == archive.lastTurnID
            && record.membershipDigest == archive.membershipDigest
            && record.turnCount == archive.turnCount
            && record.codec == archive.codec
            && record.formatVersion == archive.formatVersion
            && record.compressedPayload == archive.compressedPayload
            && record.uncompressedBytes == archive.uncompressedBytes
            && record.payloadChecksum == archive.payloadChecksum
    }

    static func archiveTurnsExactlyEqual(
        _ lhs: [ArchivedConversationTurn],
        _ rhs: [ArchivedConversationTurn]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id
                && left.role == right.role
                && left.content == right.content
                && left.timestamp.bitPattern == right.timestamp.bitPattern
                && left.sessionID == right.sessionID
                && left.petID == right.petID
                && left.petName == right.petName
        }
    }

    static func archiveDeleteTurns(
        sessionID: String,
        exactIDs: [Int64],
        database: OpaquePointer?
    ) throws {
        guard !exactIDs.isEmpty else {
            throw ConversationArchiveStoreError.invalidCandidate
        }
        let placeholders = Array(repeating: "?", count: exactIDs.count).joined(separator: ",")
        let statement = try archivePrepare(
            "DELETE FROM conversation_turns WHERE session_id = ? AND id IN (\(placeholders));",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(text: sessionID, index: 1, statement: statement, database: database)
        for (offset, id) in exactIDs.enumerated() {
            try archiveBind(
                int64: id,
                index: Int32(offset + 2),
                statement: statement,
                database: database
            )
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveDeleteRows(
        table: String,
        column: String,
        value: String,
        database: OpaquePointer?
    ) throws {
        let statement = try archivePrepare(
            "DELETE FROM \(table) WHERE \(column) = ?;",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try archiveBind(text: value, index: 1, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveTransaction(
        database: OpaquePointer?,
        body: () throws -> Void
    ) throws {
        try archiveExecute("BEGIN IMMEDIATE;", database: database)
        do {
            try body()
            try archiveExecute("COMMIT;", database: database)
        } catch {
            let original = String(describing: error)
            do {
                try archiveExecute("ROLLBACK;", database: database)
            } catch {
                throw ConversationArchiveStoreError.rollbackFailed(
                    original: original,
                    rollback: String(describing: error)
                )
            }
            throw error
        }
    }

    static func archivePrepare(
        _ sql: String,
        database: OpaquePointer?
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw archiveSQLiteError(database: database)
        }
        return statement
    }

    static func archiveExecute(_ sql: String, database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveBind(
        text: String,
        index: Int32,
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else {
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveBind(
        int64: Int64,
        index: Int32,
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        guard sqlite3_bind_int64(statement, index, int64) == SQLITE_OK else {
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveBind(
        data: Data,
        index: Int32,
        statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard result == SQLITE_OK else {
            throw archiveSQLiteError(database: database)
        }
    }

    static func archiveColumnText(index: Int32, statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    static func archiveOptionalColumnText(
        index: Int32,
        statement: OpaquePointer?
    ) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    static func archiveColumnData(
        index: Int32,
        statement: OpaquePointer?
    ) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    static func archiveSQLiteError(
        database: OpaquePointer?
    ) -> ConversationArchiveSQLiteError {
        ConversationArchiveSQLiteError(
            message: sqlite3_errmsg(database).map(String.init(cString:))
                ?? "Unknown SQLite error."
        )
    }
}

private enum ConversationArchiveStoreError: LocalizedError, Sendable {
    case invalidHotLimit
    case invalidChunkSize
    case invalidCandidate
    case overlappingArchive
    case storedArchiveMismatch
    case sourceRowsChanged
    case affectedRowCountMismatch
    case invalidStoredRecord
    case archiveNotFound
    case rollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .invalidHotLimit: "Conversation archive hot limit cannot be negative."
        case .invalidChunkSize: "Conversation archive chunk size must be between 1 and 250."
        case .invalidCandidate: "Conversation archive candidate selection was inconsistent."
        case .overlappingArchive: "Conversation archive overlaps a non-identical stored archive."
        case .storedArchiveMismatch: "Stored conversation archive failed read-back verification."
        case .sourceRowsChanged: "Conversation source rows changed during archive verification."
        case .affectedRowCountMismatch: "Conversation archive deleted an unexpected number of rows."
        case .invalidStoredRecord: "Stored conversation archive contains invalid values."
        case .archiveNotFound: "Conversation archive was not found."
        case let .rollbackFailed(original, rollback):
            "Conversation archive failed (\(original)); rollback also failed (\(rollback))."
        }
    }
}

private struct ConversationArchiveSQLiteError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
