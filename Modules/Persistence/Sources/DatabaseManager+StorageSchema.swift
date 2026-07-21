import Foundation
import SQLite3

extension DatabaseManager {
    public func initializeStorage() throws -> StorageSchemaReadiness {
        let database = try getOrOpenDatabase()

        let existingVersion = try Self.storageScalarInt("PRAGMA user_version;", in: database)
        guard existingVersion <= Int64(StorageSchema.currentVersion) else {
            throw StorageSchemaMigrationError.unsupportedVersion(Int(existingVersion))
        }

        let applicationTableCount = try Self.storageScalarInt(
            """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%';
            """,
            in: database
        )
        let autoVacuumMode = try Self.storageScalarInt("PRAGMA auto_vacuum;", in: database)
        let isNewDatabase = existingVersion == 0
            && applicationTableCount == 0
            && autoVacuumMode == 2

        if isNewDatabase {
            guard autoVacuumMode == 2 else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "New database did not enable incremental auto-vacuum."
                )
            }
        }

        try Self.storageExecute("BEGIN IMMEDIATE;", in: database)
        do {
            try Self.createApplicationTables(in: database)
            try Self.addLegacyColumnsIfNeeded(in: database)
            try Self.createStorageTables(in: database)
            try Self.addStorageColumnsIfNeeded(in: database)
            try Self.initializeFileEventMigrationMetadata(in: database)
            try Self.createCoreIndexes(in: database)

            if isNewDatabase {
                try Self.storageExecute(
                    """
                    CREATE INDEX IF NOT EXISTS idx_events_source_timestamp_id
                    ON events(source, timestamp, id);
                    """,
                    in: database
                )
            }

            let optimized = try Self.storageIndexMatches(
                named: "idx_events_source_timestamp_id",
                table: "events",
                columns: ["source", "timestamp", "id"],
                unique: false,
                in: database
            )
            if isNewDatabase && !optimized {
                throw StorageSchemaMigrationError.verificationFailed(
                    "New database optimized events index could not be verified."
                )
            }

            try Self.writeOptimizedIndexState(optimized ? "ready" : "deferred", in: database)
            try Self.verifyCoreSchema(in: database)

            try Self.storageExecute(
                "PRAGMA user_version = \(StorageSchema.currentVersion);",
                in: database
            )
            let storedVersion = try Self.storageScalarInt("PRAGMA user_version;", in: database)
            guard storedVersion == Int64(StorageSchema.currentVersion) else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Storage schema version was not persisted."
                )
            }

            try Self.storageExecute("COMMIT;", in: database)
            return StorageSchemaReadiness(
                coreReady: true,
                optimized: optimized,
                degradedReason: optimized
                    ? nil
                    : "Optimized events index creation is deferred for this existing database."
            )
        } catch {
            let originalDescription = String(describing: error)
            do {
                try Self.storageExecute("ROLLBACK;", in: database)
            } catch {
                throw StorageSchemaMigrationError.rollbackFailed(
                    original: originalDescription,
                    rollback: String(describing: error)
                )
            }
            throw error
        }
    }

    public func currentStorageSchemaReadiness() throws -> StorageSchemaReadiness {
        let database = try getOrOpenDatabase()
        try Self.verifyCoreSchema(in: database)
        let optimized = try Self.storageIndexMatches(
            named: "idx_events_source_timestamp_id",
            table: "events",
            columns: ["source", "timestamp", "id"],
            unique: false,
            in: database
        )
        try Self.writeOptimizedIndexState(optimized ? "ready" : "deferred", in: database)
        return Self.storageReadiness(optimized: optimized)
    }

    public func currentStorageFeatureGates() throws -> StorageFeatureGates {
        let readiness = try currentStorageSchemaReadiness()
        return StorageFeatureGates(
            retentionEnabled: readiness.coreReady,
            fullCompactionEnabled: readiness.optimized,
            schedulerEnabled: readiness.optimized
        )
    }

    func promoteOptimizedEventsIndexAfterBoundedMaintenance() throws -> StorageSchemaReadiness {
        let database = try getOrOpenDatabase()
        do {
            try Self.storageExecute(
                """
                CREATE INDEX IF NOT EXISTS idx_events_source_timestamp_id
                ON events(source, timestamp, id);
                """,
                in: database
            )
            let optimized = try Self.storageIndexMatches(
                named: "idx_events_source_timestamp_id",
                table: "events",
                columns: ["source", "timestamp", "id"],
                unique: false,
                in: database
            )
            guard optimized else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Optimized events index could not be verified after bounded maintenance."
                )
            }
            try Self.writeOptimizedIndexState("ready", in: database)
            return Self.storageReadiness(optimized: true)
        } catch {
            try? Self.writeOptimizedIndexState("deferred", in: database)
            return StorageSchemaReadiness(
                coreReady: true,
                optimized: false,
                degradedReason: "Optimized events index remains deferred: \(error.localizedDescription)"
            )
        }
    }
}

private extension DatabaseManager {
    enum StorageDDLToken: Equatable {
        case bareWord(String)
        case quotedIdentifier(String)
        case number(String)
        case stringLiteral
        case symbol(String)
    }

    enum StorageCheckToken: Equatable {
        case identifier(String)
        case number(String)
        case stringLiteral
        case symbol(String)
    }

    struct StorageColumnInfo {
        let columnID: Int
        let name: String
        let declaredType: String
        let isNotNull: Bool
        let defaultValue: String?
        let primaryKeyPosition: Int
    }

    struct ExpectedStorageColumn {
        let name: String
        let declaredType: String
        let isNotNull: Bool?
        let defaultValue: String?
        let primaryKeyPosition: Int?

        init(
            _ name: String,
            _ declaredType: String,
            isNotNull: Bool? = nil,
            defaultValue: String? = nil,
            primaryKeyPosition: Int? = nil
        ) {
            self.name = name
            self.declaredType = declaredType
            self.isNotNull = isNotNull
            self.defaultValue = defaultValue
            self.primaryKeyPosition = primaryKeyPosition
        }
    }

    static func createApplicationTables(in database: OpaquePointer?) throws {
        try storageExecute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT DEFAULT(datetime('now')),
                source TEXT,
                payload TEXT
            );

            CREATE TABLE IF NOT EXISTS pet_state (
                pet_id TEXT PRIMARY KEY,
                animation_state TEXT,
                position_x REAL,
                position_y REAL,
                screen_id TEXT
            );

            CREATE TABLE IF NOT EXISTS conversation_turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                session_id TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                participant_ids TEXT NOT NULL,
                title TEXT NOT NULL,
                last_message TEXT DEFAULT '',
                last_timestamp REAL DEFAULT 0,
                unread_count INTEGER DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS ai_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                category TEXT NOT NULL,
                created_at REAL NOT NULL,
                importance INTEGER DEFAULT 1
            );
            """,
            in: database
        )
    }

    static func addLegacyColumnsIfNeeded(in database: OpaquePointer?) throws {
        try addColumnIfNeeded(
            table: "conversation_turns",
            column: "pet_id",
            definition: "pet_id TEXT",
            in: database
        )
        try addColumnIfNeeded(
            table: "conversation_turns",
            column: "pet_name",
            definition: "pet_name TEXT",
            in: database
        )
        try addColumnIfNeeded(
            table: "ai_memories",
            column: "content_hash",
            definition: "content_hash TEXT",
            in: database
        )
        try addColumnIfNeeded(
            table: "ai_memories",
            column: "remote_id",
            definition: "remote_id TEXT",
            in: database
        )
        try addColumnIfNeeded(
            table: "ai_memories",
            column: "synced_at",
            definition: "synced_at REAL",
            in: database
        )
        try addColumnIfNeeded(
            table: "ai_memories",
            column: "source",
            definition: "source TEXT DEFAULT 'auto'",
            in: database
        )
    }

    static func createStorageTables(in database: OpaquePointer?) throws {
        try storageExecute(
            """
            CREATE TABLE IF NOT EXISTS conversation_archives (
                archive_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                first_turn_id INTEGER NOT NULL,
                last_turn_id INTEGER NOT NULL,
                membership_digest TEXT NOT NULL,
                turn_count INTEGER NOT NULL CHECK (turn_count > 0),
                codec TEXT NOT NULL,
                format_version INTEGER NOT NULL,
                compressed_payload BLOB NOT NULL,
                uncompressed_bytes INTEGER NOT NULL,
                payload_checksum TEXT NOT NULL,
                created_at REAL NOT NULL,
                CHECK (first_turn_id <= last_turn_id)
            );

            CREATE TABLE IF NOT EXISTS event_hourly_rollups (
                bucket_start INTEGER NOT NULL,
                source TEXT NOT NULL,
                event_count INTEGER NOT NULL CHECK (event_count >= 0),
                PRIMARY KEY (bucket_start, source)
            );

            CREATE TABLE IF NOT EXISTS event_rollup_batches (
                batch_id TEXT PRIMARY KEY,
                digest TEXT NOT NULL,
                format_version INTEGER NOT NULL,
                committed_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS storage_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,
            in: database
        )
    }

    static func addStorageColumnsIfNeeded(in database: OpaquePointer?) throws {
        try addColumnIfNeeded(
            table: "events",
            column: "rollup_accounted",
            definition: "rollup_accounted INTEGER NOT NULL DEFAULT 0 CHECK (rollup_accounted IN (0, 1))",
            in: database
        )
    }

    static func initializeFileEventMigrationMetadata(in database: OpaquePointer?) throws {
        try storageExecute(
            """
            INSERT OR IGNORE INTO storage_metadata(key, value)
            SELECT
                'file_event_migration_high_watermark',
                CAST(COALESCE(MAX(id), 0) AS TEXT)
            FROM events
            WHERE source = 'fileChanged';
            """,
            in: database
        )

        let watermark: Int64
        do {
            let statement = try storagePrepare(
                """
                SELECT value
                FROM storage_metadata
                WHERE key = 'file_event_migration_high_watermark';
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let rawWatermark = sqlite3_column_text(statement, 0),
                  let parsedWatermark = Int64(String(cString: rawWatermark)),
                  parsedWatermark >= 0 else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "File-event migration watermark is missing or invalid."
                )
            }
            watermark = parsedWatermark
        }

        let hasPendingLegacyRows: Bool
        do {
            let statement = try storagePrepare(
                """
                SELECT EXISTS(
                    SELECT 1
                    FROM events
                    WHERE source = 'fileChanged'
                      AND rollup_accounted = 0
                      AND id <= ?
                );
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_int64(statement, 1, watermark) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw storageSQLiteError(in: database)
            }
            hasPendingLegacyRows = sqlite3_column_int64(statement, 0) != 0
        }

        if !hasPendingLegacyRows {
            try storageExecute(
                """
                INSERT INTO storage_metadata(key, value)
                VALUES ('file_event_migration_complete', '1')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """,
                in: database
            )
        } else {
            try storageExecute(
                "DELETE FROM storage_metadata WHERE key = 'file_event_migration_complete';",
                in: database
            )
        }
    }

    static func createCoreIndexes(in database: OpaquePointer?) throws {
        try storageExecute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_memories_content_hash
            ON ai_memories(content_hash);

            CREATE INDEX IF NOT EXISTS idx_conversation_turns_session_id_id
            ON conversation_turns(session_id, id);

            CREATE INDEX IF NOT EXISTS idx_conversation_archives_session_range
            ON conversation_archives(session_id, first_turn_id, last_turn_id);

            CREATE INDEX IF NOT EXISTS idx_event_rollup_batches_committed_at
            ON event_rollup_batches(committed_at);
            """,
            in: database
        )
    }

    static func writeOptimizedIndexState(_ state: String, in database: OpaquePointer?) throws {
        let statement = try storagePrepare(
            """
            INSERT INTO storage_metadata(key, value)
            VALUES ('optimized_index_state', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try storageBind(text: state, at: 1, in: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storageSQLiteError(in: database)
        }
    }

    static func storageReadiness(optimized: Bool) -> StorageSchemaReadiness {
        StorageSchemaReadiness(
            coreReady: true,
            optimized: optimized,
            degradedReason: optimized
                ? nil
                : "Optimized events index creation is deferred for this existing database."
        )
    }

    static func addColumnIfNeeded(
        table: String,
        column: String,
        definition: String,
        in database: OpaquePointer?
    ) throws {
        let columns = try storageColumns(in: table, database: database)
        guard !columns.contains(where: { $0.name == column }) else { return }
        try storageExecute("ALTER TABLE \(table) ADD COLUMN \(definition);", in: database)
    }

    static func verifyCoreSchema(in database: OpaquePointer?) throws {
        try requireColumns(
            in: "events",
            expected: [
                ExpectedStorageColumn("id", "INTEGER", primaryKeyPosition: 1),
                ExpectedStorageColumn("timestamp", "TEXT", defaultValue: "datetime('now')"),
                ExpectedStorageColumn("source", "TEXT"),
                ExpectedStorageColumn("payload", "TEXT"),
                ExpectedStorageColumn(
                    "rollup_accounted",
                    "INTEGER",
                    isNotNull: true,
                    defaultValue: "0",
                    primaryKeyPosition: 0
                ),
            ],
            exact: false,
            database: database
        )
        try requireColumns(
            in: "conversation_turns",
            expected: [
                ExpectedStorageColumn("id", "INTEGER", primaryKeyPosition: 1),
                ExpectedStorageColumn("role", "TEXT", isNotNull: true),
                ExpectedStorageColumn("content", "TEXT", isNotNull: true),
                ExpectedStorageColumn("timestamp", "REAL", isNotNull: true),
                ExpectedStorageColumn("session_id", "TEXT", isNotNull: true),
                ExpectedStorageColumn("pet_id", "TEXT"),
                ExpectedStorageColumn("pet_name", "TEXT"),
            ],
            exact: false,
            database: database
        )
        try requireColumns(
            in: "ai_memories",
            expected: [
                ExpectedStorageColumn("id", "INTEGER", primaryKeyPosition: 1),
                ExpectedStorageColumn("content", "TEXT", isNotNull: true),
                ExpectedStorageColumn("category", "TEXT", isNotNull: true),
                ExpectedStorageColumn("created_at", "REAL", isNotNull: true),
                ExpectedStorageColumn("importance", "INTEGER"),
                ExpectedStorageColumn("content_hash", "TEXT"),
                ExpectedStorageColumn("remote_id", "TEXT"),
                ExpectedStorageColumn("synced_at", "REAL"),
                ExpectedStorageColumn("source", "TEXT", defaultValue: "'auto'"),
            ],
            exact: false,
            database: database
        )

        try requireColumns(
            in: "conversation_archives",
            expected: [
                ExpectedStorageColumn("archive_id", "TEXT", primaryKeyPosition: 1),
                ExpectedStorageColumn("session_id", "TEXT", isNotNull: true),
                ExpectedStorageColumn("first_turn_id", "INTEGER", isNotNull: true),
                ExpectedStorageColumn("last_turn_id", "INTEGER", isNotNull: true),
                ExpectedStorageColumn("membership_digest", "TEXT", isNotNull: true),
                ExpectedStorageColumn("turn_count", "INTEGER", isNotNull: true),
                ExpectedStorageColumn("codec", "TEXT", isNotNull: true),
                ExpectedStorageColumn("format_version", "INTEGER", isNotNull: true),
                ExpectedStorageColumn("compressed_payload", "BLOB", isNotNull: true),
                ExpectedStorageColumn("uncompressed_bytes", "INTEGER", isNotNull: true),
                ExpectedStorageColumn("payload_checksum", "TEXT", isNotNull: true),
                ExpectedStorageColumn("created_at", "REAL", isNotNull: true),
            ],
            exact: true,
            database: database
        )
        try requireColumns(
            in: "event_hourly_rollups",
            expected: [
                ExpectedStorageColumn(
                    "bucket_start",
                    "INTEGER",
                    isNotNull: true,
                    primaryKeyPosition: 1
                ),
                ExpectedStorageColumn(
                    "source",
                    "TEXT",
                    isNotNull: true,
                    primaryKeyPosition: 2
                ),
                ExpectedStorageColumn("event_count", "INTEGER", isNotNull: true),
            ],
            exact: true,
            database: database
        )
        try requireColumns(
            in: "event_rollup_batches",
            expected: [
                ExpectedStorageColumn("batch_id", "TEXT", primaryKeyPosition: 1),
                ExpectedStorageColumn("digest", "TEXT", isNotNull: true),
                ExpectedStorageColumn("format_version", "INTEGER", isNotNull: true),
                ExpectedStorageColumn("committed_at", "REAL", isNotNull: true),
            ],
            exact: true,
            database: database
        )
        try requireColumns(
            in: "storage_metadata",
            expected: [
                ExpectedStorageColumn("key", "TEXT", primaryKeyPosition: 1),
                ExpectedStorageColumn("value", "TEXT", isNotNull: true),
            ],
            exact: true,
            database: database
        )

        try requireExactCheckExpressions(
            table: "events",
            expressions: ["rollup_accounted IN (0, 1)"],
            database: database
        )
        try requireExactCheckExpressions(
            table: "conversation_archives",
            expressions: ["turn_count > 0", "first_turn_id <= last_turn_id"],
            database: database
        )
        try requireExactCheckExpressions(
            table: "event_hourly_rollups",
            expressions: ["event_count >= 0"],
            database: database
        )
        try verifyStorageCheckConstraints(in: database)

        try requireIndex(
            named: "idx_ai_memories_content_hash",
            table: "ai_memories",
            columns: ["content_hash"],
            unique: true,
            database: database
        )
        try requireIndex(
            named: "idx_conversation_turns_session_id_id",
            table: "conversation_turns",
            columns: ["session_id", "id"],
            unique: false,
            database: database
        )
        try requireIndex(
            named: "idx_conversation_archives_session_range",
            table: "conversation_archives",
            columns: ["session_id", "first_turn_id", "last_turn_id"],
            unique: false,
            database: database
        )
        try requireIndex(
            named: "idx_event_rollup_batches_committed_at",
            table: "event_rollup_batches",
            columns: ["committed_at"],
            unique: false,
            database: database
        )
    }

    static func requireColumns(
        in table: String,
        expected: [ExpectedStorageColumn],
        exact: Bool,
        database: OpaquePointer?
    ) throws {
        let actual = try storageColumns(in: table, database: database)
        let actualByName = Dictionary(uniqueKeysWithValues: actual.map { ($0.name, $0) })

        if exact && Set(actualByName.keys) != Set(expected.map(\.name)) {
            throw StorageSchemaMigrationError.verificationFailed(
                "Table \(table) has unexpected columns."
            )
        }

        for required in expected {
            guard let column = actualByName[required.name],
                  column.declaredType.caseInsensitiveCompare(required.declaredType) == .orderedSame else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Table \(table) is missing a valid \(required.name) column."
                )
            }
            if let expectedNotNull = required.isNotNull,
               column.isNotNull != expectedNotNull {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Table \(table).\(required.name) has an invalid nullability constraint."
                )
            }
            if let expectedDefault = required.defaultValue,
               normalizeDefault(column.defaultValue) != normalizeDefault(expectedDefault) {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Table \(table).\(required.name) has an invalid default value."
                )
            }
            if let expectedPrimaryKeyPosition = required.primaryKeyPosition,
               column.primaryKeyPosition != expectedPrimaryKeyPosition {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Table \(table).\(required.name) has an invalid primary-key definition."
                )
            }
        }
    }

    static func requireExactCheckExpressions(
        table: String,
        expressions: [String],
        database: OpaquePointer?
    ) throws {
        guard let sql = try storageSchemaSQL(forTable: table, database: database) else {
            throw StorageSchemaMigrationError.verificationFailed(
                "Table \(table) has no verifiable schema."
            )
        }

        let schemaTokens = try storageDDLTokens(in: sql, label: "table \(table)")
        let actualExpressions = try storageCheckExpressions(
            in: schemaTokens,
            label: "table \(table)"
        )

        for expression in expressions {
            let expectedTokens = try storageDDLTokens(
                in: expression,
                label: "required CHECK \(expression)"
            )
            let expectedExpression = storageCanonicalCheckExpression(expectedTokens)
            guard !expectedExpression.isEmpty,
                  actualExpressions.contains(expectedExpression) else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Table \(table) is missing standalone CHECK (\(expression))."
                )
            }
        }
    }

    static func storageDDLTokens(
        in sql: String,
        label: String
    ) throws -> [StorageDDLToken] {
        let characters = Array(sql)
        var tokens: [StorageDDLToken] = []
        var offset = 0

        func isBareWordStart(_ character: Character) -> Bool {
            character.isLetter || character == "_" || character == "$"
        }

        func isBareWordContinuation(_ character: Character) -> Bool {
            isBareWordStart(character) || character.isNumber
        }

        while offset < characters.count {
            let character = characters[offset]
            if character.isWhitespace {
                offset += 1
                continue
            }

            if character == "-", offset + 1 < characters.count,
               characters[offset + 1] == "-" {
                offset += 2
                while offset < characters.count,
                      characters[offset] != "\n", characters[offset] != "\r" {
                    offset += 1
                }
                continue
            }

            if character == "/", offset + 1 < characters.count,
               characters[offset + 1] == "*" {
                offset += 2
                var foundTerminator = false
                while offset + 1 < characters.count {
                    if characters[offset] == "*", characters[offset + 1] == "/" {
                        offset += 2
                        foundTerminator = true
                        break
                    }
                    offset += 1
                }
                guard foundTerminator else {
                    throw StorageSchemaMigrationError.verificationFailed(
                        "Could not parse \(label): unterminated SQL comment."
                    )
                }
                continue
            }

            if character == "'" {
                offset += 1
                var foundTerminator = false
                while offset < characters.count {
                    guard characters[offset] == "'" else {
                        offset += 1
                        continue
                    }
                    if offset + 1 < characters.count, characters[offset + 1] == "'" {
                        offset += 2
                    } else {
                        offset += 1
                        foundTerminator = true
                        break
                    }
                }
                guard foundTerminator else {
                    throw StorageSchemaMigrationError.verificationFailed(
                        "Could not parse \(label): unterminated SQL string."
                    )
                }
                tokens.append(.stringLiteral)
                continue
            }

            if character == "\"" || character == "`" || character == "[" {
                let terminator: Character = character == "[" ? "]" : character
                offset += 1
                var identifier: [Character] = []
                var foundTerminator = false
                while offset < characters.count {
                    let current = characters[offset]
                    guard current == terminator else {
                        identifier.append(current)
                        offset += 1
                        continue
                    }
                    if offset + 1 < characters.count,
                       characters[offset + 1] == terminator {
                        identifier.append(terminator)
                        offset += 2
                    } else {
                        offset += 1
                        foundTerminator = true
                        break
                    }
                }
                guard foundTerminator else {
                    throw StorageSchemaMigrationError.verificationFailed(
                        "Could not parse \(label): unterminated quoted identifier."
                    )
                }
                tokens.append(.quotedIdentifier(String(identifier).lowercased()))
                continue
            }

            if isBareWordStart(character) {
                let start = offset
                offset += 1
                while offset < characters.count,
                      isBareWordContinuation(characters[offset]) {
                    offset += 1
                }
                tokens.append(
                    .bareWord(String(characters[start..<offset]).lowercased())
                )
                continue
            }

            if character.isNumber {
                let start = offset
                offset += 1
                while offset < characters.count, characters[offset].isNumber {
                    offset += 1
                }
                tokens.append(.number(String(characters[start..<offset])))
                continue
            }

            if offset + 1 < characters.count {
                let pair = String(characters[offset...offset + 1])
                if ["<=", ">=", "<>", "!=", "==", "||", "&&", "<<", ">>", "->"].contains(pair) {
                    tokens.append(.symbol(pair))
                    offset += 2
                    continue
                }
            }

            tokens.append(.symbol(String(character)))
            offset += 1
        }

        return tokens
    }

    static func storageCheckExpressions(
        in tokens: [StorageDDLToken],
        label: String
    ) throws -> [[StorageCheckToken]] {
        var tableDepth = 0
        for token in tokens {
            if token == .symbol("(") {
                tableDepth += 1
            } else if token == .symbol(")") {
                tableDepth -= 1
                guard tableDepth >= 0 else {
                    throw StorageSchemaMigrationError.verificationFailed(
                        "Could not parse \(label): unbalanced parentheses."
                    )
                }
            }
        }
        guard tableDepth == 0 else {
            throw StorageSchemaMigrationError.verificationFailed(
                "Could not parse \(label): unbalanced parentheses."
            )
        }

        var expressions: [[StorageCheckToken]] = []
        var offset = 0
        while offset < tokens.count {
            guard tokens[offset] == .bareWord("check"),
                  offset + 1 < tokens.count,
                  tokens[offset + 1] == .symbol("(") else {
                offset += 1
                continue
            }

            var depth = 1
            var end = offset + 2
            while end < tokens.count, depth > 0 {
                if tokens[end] == .symbol("(") {
                    depth += 1
                } else if tokens[end] == .symbol(")") {
                    depth -= 1
                }
                if depth > 0 {
                    end += 1
                }
            }
            guard depth == 0 else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Could not parse \(label): unterminated CHECK expression."
                )
            }

            let expressionTokens = Array(tokens[(offset + 2)..<end])
            let expression = storageCanonicalCheckExpression(expressionTokens)
            guard !expression.isEmpty else {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Could not parse \(label): empty CHECK expression."
                )
            }
            expressions.append(expression)
            offset = end + 1
        }
        return expressions
    }

    static func storageCanonicalCheckExpression(
        _ tokens: [StorageDDLToken]
    ) -> [StorageCheckToken] {
        var result = tokens.map { token -> StorageCheckToken in
            switch token {
            case let .bareWord(value), let .quotedIdentifier(value):
                return .identifier(value)
            case let .number(value):
                return .number(value)
            case .stringLiteral:
                return .stringLiteral
            case let .symbol(value):
                return .symbol(value)
            }
        }

        while storageHasSingleOuterParentheses(result) {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    static func storageHasSingleOuterParentheses(_ tokens: [StorageCheckToken]) -> Bool {
        guard tokens.count >= 2,
              tokens.first == .symbol("("), tokens.last == .symbol(")") else {
            return false
        }

        var depth = 0
        for (offset, token) in tokens.enumerated() {
            if token == .symbol("(") {
                depth += 1
            } else if token == .symbol(")") {
                depth -= 1
                if depth == 0, offset != tokens.count - 1 {
                    return false
                }
            }
            if depth < 0 {
                return false
            }
        }
        return depth == 0
    }

    static func verifyStorageCheckConstraints(in database: OpaquePointer?) throws {
        let probeID = "__vitapet_storage_check_\(UUID().uuidString)__"
        try storageExecute("SAVEPOINT vitapet_storage_constraint_probe;", in: database)
        do {
            try requireCheckConstraintViolation(
                controlSQL: """
                INSERT INTO conversation_archives(
                    archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                    turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                    payload_checksum, created_at
                ) VALUES (?, ?, 1, 1, ?, 1, 'probe', 1, X'00', 1, ?, 0);
                """,
                invalidSQL: """
                INSERT INTO conversation_archives(
                    archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                    turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                    payload_checksum, created_at
                ) VALUES (?, ?, 1, 1, ?, 0, 'probe', 1, X'00', 1, ?, 0);
                """,
                bindings: ["\(probeID)-count", probeID, probeID, probeID],
                label: "conversation_archives.turn_count",
                database: database
            )
            try requireCheckConstraintViolation(
                controlSQL: """
                INSERT INTO conversation_archives(
                    archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                    turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                    payload_checksum, created_at
                ) VALUES (?, ?, 2, 2, ?, 1, 'probe', 1, X'00', 1, ?, 0);
                """,
                invalidSQL: """
                INSERT INTO conversation_archives(
                    archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                    turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                    payload_checksum, created_at
                ) VALUES (?, ?, 2, 1, ?, 1, 'probe', 1, X'00', 1, ?, 0);
                """,
                bindings: ["\(probeID)-range", probeID, probeID, probeID],
                label: "conversation_archives turn range",
                database: database
            )
            try requireCheckConstraintViolation(
                controlSQL: """
                INSERT INTO event_hourly_rollups(bucket_start, source, event_count)
                VALUES (-9223372036854775807, ?, 0);
                """,
                invalidSQL: """
                INSERT INTO event_hourly_rollups(bucket_start, source, event_count)
                VALUES (-9223372036854775807, ?, -1);
                """,
                bindings: [probeID],
                label: "event_hourly_rollups.event_count",
                database: database
            )
            try requireCheckConstraintViolation(
                controlSQL: """
                INSERT INTO events(source, payload, rollup_accounted)
                VALUES (?, '{}', 1);
                """,
                invalidSQL: """
                INSERT INTO events(source, payload, rollup_accounted)
                VALUES (?, '{}', 2);
                """,
                bindings: [probeID],
                label: "events.rollup_accounted",
                database: database
            )
        } catch {
            let probeError = String(describing: error)
            do {
                try storageExecute(
                    "ROLLBACK TO SAVEPOINT vitapet_storage_constraint_probe;",
                    in: database
                )
                try storageExecute(
                    "RELEASE SAVEPOINT vitapet_storage_constraint_probe;",
                    in: database
                )
            } catch {
                throw StorageSchemaMigrationError.verificationFailed(
                    "Storage CHECK probe failed (\(probeError)); savepoint cleanup also failed (\(error))."
                )
            }
            throw error
        }

        try storageExecute(
            "ROLLBACK TO SAVEPOINT vitapet_storage_constraint_probe;",
            in: database
        )
        try storageExecute(
            "RELEASE SAVEPOINT vitapet_storage_constraint_probe;",
            in: database
        )
    }

    static func requireCheckConstraintViolation(
        controlSQL: String,
        invalidSQL: String,
        bindings: [String],
        label: String,
        database: OpaquePointer?
    ) throws {
        try requireSuccessfulStorageProbe(
            controlSQL,
            bindings: bindings,
            label: label,
            database: database
        )
        try storageExecute(
            "ROLLBACK TO SAVEPOINT vitapet_storage_constraint_probe;",
            in: database
        )

        let statement = try storagePrepare(invalidSQL, in: database)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try storageBind(
                text: value,
                at: Int32(offset + 1),
                in: statement,
                database: database
            )
        }

        let result = sqlite3_step(statement)
        let extendedResult = sqlite3_extended_errcode(database)
        let checkConstraintResult = SQLITE_CONSTRAINT | (1 << 8)
        guard result & 0xff == SQLITE_CONSTRAINT,
              extendedResult == checkConstraintResult else {
            let message = sqlite3_errmsg(database).map(String.init(cString:))
                ?? "Unknown SQLite error."
            throw StorageSchemaMigrationError.verificationFailed(
                "Storage CHECK probe for \(label) returned SQLite \(result)/\(extendedResult): \(message)"
            )
        }

        try storageExecute(
            "ROLLBACK TO SAVEPOINT vitapet_storage_constraint_probe;",
            in: database
        )
    }

    static func requireSuccessfulStorageProbe(
        _ sql: String,
        bindings: [String],
        label: String,
        database: OpaquePointer?
    ) throws {
        let statement = try storagePrepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try storageBind(
                text: value,
                at: Int32(offset + 1),
                in: statement,
                database: database
            )
        }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            let extendedResult = sqlite3_extended_errcode(database)
            let message = sqlite3_errmsg(database).map(String.init(cString:))
                ?? "Unknown SQLite error."
            throw StorageSchemaMigrationError.verificationFailed(
                "Storage CHECK control for \(label) returned SQLite \(result)/\(extendedResult): \(message)"
            )
        }
    }

    static func requireIndex(
        named name: String,
        table: String,
        columns: [String],
        unique: Bool,
        database: OpaquePointer?
    ) throws {
        guard try storageIndexMatches(
            named: name,
            table: table,
            columns: columns,
            unique: unique,
            in: database
        ) else {
            throw StorageSchemaMigrationError.verificationFailed(
                "Index \(name) does not match its required definition."
            )
        }
    }

    static func storageColumns(
        in table: String,
        database: OpaquePointer?
    ) throws -> [StorageColumnInfo] {
        let statement = try storagePrepare(
            "PRAGMA table_info(\(storageQuotedIdentifier(table)));",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        var columns: [StorageColumnInfo] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                columns.append(
                    StorageColumnInfo(
                        columnID: Int(sqlite3_column_int(statement, 0)),
                        name: storageColumnText(at: 1, in: statement),
                        declaredType: storageColumnText(at: 2, in: statement),
                        isNotNull: sqlite3_column_int(statement, 3) != 0,
                        defaultValue: sqlite3_column_type(statement, 4) == SQLITE_NULL
                            ? nil
                            : storageColumnText(at: 4, in: statement),
                        primaryKeyPosition: Int(sqlite3_column_int(statement, 5))
                    )
                )
            case SQLITE_DONE:
                return columns
            default:
                throw storageSQLiteError(in: database)
            }
        }
    }

    static func storageSchemaSQL(
        forTable table: String,
        database: OpaquePointer?
    ) throws -> String? {
        let statement = try storagePrepare(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try storageBind(text: table, at: 1, in: statement, database: database)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return storageColumnText(at: 0, in: statement)
        case SQLITE_DONE:
            return nil
        default:
            throw storageSQLiteError(in: database)
        }
    }

    static func storageIndexMatches(
        named name: String,
        table: String,
        columns: [String],
        unique: Bool,
        in database: OpaquePointer?
    ) throws -> Bool {
        let listStatement = try storagePrepare(
            "PRAGMA index_list(\(storageQuotedIdentifier(table)));",
            in: database
        )
        defer { sqlite3_finalize(listStatement) }
        var foundMatchingName = false
        indexListLoop: while true {
            switch sqlite3_step(listStatement) {
            case SQLITE_ROW:
                guard storageColumnText(at: 1, in: listStatement) == name else { continue }
                foundMatchingName = true
                let isUnique = sqlite3_column_int(listStatement, 2) != 0
                let isPartial = sqlite3_column_int(listStatement, 4) != 0
                guard isUnique == unique, !isPartial else { return false }
            case SQLITE_DONE:
                break indexListLoop
            default:
                throw storageSQLiteError(in: database)
            }
        }
        guard foundMatchingName else { return false }

        let tableColumns = try storageColumns(in: table, database: database)
        let columnIDsByName = Dictionary(
            uniqueKeysWithValues: tableColumns.map { ($0.name, $0.columnID) }
        )
        guard columns.allSatisfy({ columnIDsByName[$0] != nil }) else { return false }

        let infoStatement = try storagePrepare(
            "PRAGMA index_xinfo(\(storageQuotedIdentifier(name)));",
            in: database
        )
        defer { sqlite3_finalize(infoStatement) }
        var keyColumnOffset = 0
        while true {
            switch sqlite3_step(infoStatement) {
            case SQLITE_ROW:
                guard sqlite3_column_int(infoStatement, 5) == 1 else { continue }
                guard keyColumnOffset < columns.count else { return false }

                let expectedName = columns[keyColumnOffset]
                guard let expectedColumnID = columnIDsByName[expectedName] else { return false }
                guard sqlite3_column_type(infoStatement, 2) != SQLITE_NULL,
                      Int(sqlite3_column_int(infoStatement, 0)) == keyColumnOffset,
                      Int(sqlite3_column_int(infoStatement, 1)) == expectedColumnID,
                      storageColumnText(at: 2, in: infoStatement) == expectedName,
                      sqlite3_column_int(infoStatement, 3) == 0,
                      storageColumnText(at: 4, in: infoStatement)
                        .caseInsensitiveCompare("BINARY") == .orderedSame else {
                    return false
                }
                keyColumnOffset += 1
            case SQLITE_DONE:
                return keyColumnOffset == columns.count
            default:
                throw storageSQLiteError(in: database)
            }
        }
    }

    static func storageQuotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func storageScalarInt(_ sql: String, in database: OpaquePointer?) throws -> Int64 {
        let statement = try storagePrepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StorageSchemaMigrationError.verificationFailed(
                "SQLite scalar query returned no value: \(sql)"
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func storageExecute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw storageSQLiteError(in: database)
        }
    }

    static func storagePrepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storageSQLiteError(in: database)
        }
        return statement
    }

    static func storageBind(
        text: String,
        at index: Int32,
        in statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else {
            throw storageSQLiteError(in: database)
        }
    }

    static func storageColumnText(at index: Int32, in statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    static func storageSQLiteError(in database: OpaquePointer?) -> StorageSchemaSQLiteError {
        StorageSchemaSQLiteError(
            message: sqlite3_errmsg(database).map(String.init(cString:)) ?? "Unknown SQLite error."
        )
    }

    static func normalizeDefault(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while storageDefaultHasSingleOuterParentheses(value) {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func storageDefaultHasSingleOuterParentheses(_ value: String) -> Bool {
        let characters = Array(value)
        guard characters.count >= 2,
              characters.first == "(", characters.last == ")" else {
            return false
        }

        var depth = 0
        var quoteTerminator: Character?
        var offset = 0
        while offset < characters.count {
            let character = characters[offset]
            if let terminator = quoteTerminator {
                guard character == terminator else {
                    offset += 1
                    continue
                }
                if offset + 1 < characters.count,
                   characters[offset + 1] == terminator {
                    offset += 2
                } else {
                    quoteTerminator = nil
                    offset += 1
                }
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
                quoteTerminator = character
            } else if character == "[" {
                quoteTerminator = "]"
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0, offset != characters.count - 1 {
                    return false
                }
                if depth < 0 {
                    return false
                }
            }
            offset += 1
        }
        return depth == 0 && quoteTerminator == nil
    }

}

private enum StorageSchemaMigrationError: LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case verificationFailed(String)
    case rollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Storage schema version \(version) is newer than this application supports."
        case let .verificationFailed(message):
            return message
        case let .rollbackFailed(original, rollback):
            return "Storage migration failed (\(original)); rollback also failed (\(rollback))."
        }
    }
}

private struct StorageSchemaSQLiteError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
