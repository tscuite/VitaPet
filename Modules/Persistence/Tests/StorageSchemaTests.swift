import Foundation
import Persistence
import SQLite3
import XCTest

final class StorageSchemaTests: XCTestCase {
    func testInitializeMigratesLegacyDatabaseWithoutDeletingRowsAndIsIdempotent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyDatabase(at: fixture.databaseURL)
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        let firstReadiness = try await manager.initializeStorage()
        let secondReadiness = try await manager.initializeStorage()
        await manager.close()

        XCTAssertTrue(firstReadiness.coreReady)
        XCTAssertFalse(firstReadiness.optimized)
        XCTAssertNotNil(firstReadiness.degradedReason)
        XCTAssertEqual(secondReadiness, firstReadiness)
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: fixture.databaseURL), 2)
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM conversation_turns;", at: fixture.databaseURL), 2)
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM ai_memories;", at: fixture.databaseURL), 1)
        XCTAssertEqual(try intScalar("PRAGMA user_version;", at: fixture.databaseURL), StorageSchema.currentVersion)
        XCTAssertEqual(try intScalar("PRAGMA auto_vacuum;", at: fixture.databaseURL), 0)

        XCTAssertEqual(
            try requiredColumnNames(in: "conversation_archives", at: fixture.databaseURL),
            [
                "archive_id", "session_id", "first_turn_id", "last_turn_id", "membership_digest",
                "turn_count", "codec", "format_version", "compressed_payload", "uncompressed_bytes",
                "payload_checksum", "created_at",
            ]
        )
        XCTAssertEqual(
            try requiredColumnNames(in: "event_hourly_rollups", at: fixture.databaseURL),
            ["bucket_start", "source", "event_count"]
        )
        XCTAssertEqual(
            try requiredColumnNames(in: "event_rollup_batches", at: fixture.databaseURL),
            ["batch_id", "digest", "format_version", "committed_at"]
        )
        XCTAssertEqual(
            try requiredColumnNames(in: "storage_metadata", at: fixture.databaseURL),
            ["key", "value"]
        )
        XCTAssertTrue(try columnExists(table: "events", column: "rollup_accounted", at: fixture.databaseURL))
        XCTAssertTrue(try columnExists(table: "conversation_turns", column: "pet_id", at: fixture.databaseURL))
        XCTAssertTrue(try columnExists(table: "conversation_turns", column: "pet_name", at: fixture.databaseURL))
        XCTAssertTrue(try columnExists(table: "ai_memories", column: "content_hash", at: fixture.databaseURL))
        XCTAssertTrue(try columnExists(table: "ai_memories", column: "remote_id", at: fixture.databaseURL))
        XCTAssertTrue(try columnExists(table: "ai_memories", column: "synced_at", at: fixture.databaseURL))
        XCTAssertTrue(try columnExists(table: "ai_memories", column: "source", at: fixture.databaseURL))

        XCTAssertEqual(
            try indexedColumns(named: "idx_conversation_turns_session_id_id", at: fixture.databaseURL),
            ["session_id", "id"]
        )
        XCTAssertEqual(
            try indexedColumns(named: "idx_conversation_archives_session_range", at: fixture.databaseURL),
            ["session_id", "first_turn_id", "last_turn_id"]
        )
        XCTAssertEqual(
            try indexedColumns(named: "idx_event_rollup_batches_committed_at", at: fixture.databaseURL),
            ["committed_at"]
        )
        XCTAssertFalse(try indexExists(named: "idx_events_source_timestamp_id", at: fixture.databaseURL))
        XCTAssertEqual(
            try textScalar(
                "SELECT value FROM storage_metadata WHERE key = 'optimized_index_state';",
                at: fixture.databaseURL
            ),
            "deferred"
        )
    }

    func testInitializeNewDatabaseEnablesIncrementalAutoVacuumAndOptimizedIndex() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        let readiness = try await manager.initializeStorage()
        await manager.close()

        XCTAssertEqual(
            readiness,
            StorageSchemaReadiness(coreReady: true, optimized: true, degradedReason: nil)
        )
        XCTAssertEqual(try intScalar("PRAGMA auto_vacuum;", at: fixture.databaseURL), 2)
        XCTAssertEqual(try intScalar("PRAGMA user_version;", at: fixture.databaseURL), StorageSchema.currentVersion)
        XCTAssertEqual(
            try indexedColumns(named: "idx_events_source_timestamp_id", at: fixture.databaseURL),
            ["source", "timestamp", "id"]
        )
    }

    func testExistingOptimizedIndexIsRecognizedWithoutRebuildingIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyDatabase(at: fixture.databaseURL, includeOptimizedIndex: true)
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        let readiness = try await manager.initializeStorage()
        await manager.close()

        XCTAssertEqual(
            readiness,
            StorageSchemaReadiness(coreReady: true, optimized: true, degradedReason: nil)
        )
        XCTAssertEqual(try intScalar("PRAGMA auto_vacuum;", at: fixture.databaseURL), 0)
    }

    func testNoCaseOptimizedIndexIsDeferred() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyDatabase(at: fixture.databaseURL)
        try execute(
            """
            CREATE INDEX idx_events_source_timestamp_id
            ON events(source COLLATE NOCASE, timestamp, id);
            """,
            at: fixture.databaseURL
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        let readiness = try await manager.initializeStorage()
        await manager.close()

        XCTAssertTrue(readiness.coreReady)
        XCTAssertFalse(readiness.optimized)
        XCTAssertNotNil(readiness.degradedReason)
    }

    func testPartialOptimizedIndexIsDeferred() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyDatabase(at: fixture.databaseURL)
        try execute(
            """
            CREATE INDEX idx_events_source_timestamp_id
            ON events(source, timestamp, id)
            WHERE source IS NOT NULL;
            """,
            at: fixture.databaseURL
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        let readiness = try await manager.initializeStorage()
        await manager.close()

        XCTAssertTrue(readiness.coreReady)
        XCTAssertFalse(readiness.optimized)
        XCTAssertNotNil(readiness.degradedReason)
    }

    func testNoCaseCoreIndexFailsAndRollsBackMigration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyDatabase(at: fixture.databaseURL)
        try execute(
            """
            CREATE INDEX idx_conversation_turns_session_id_id
            ON conversation_turns(session_id COLLATE NOCASE, id);
            """,
            at: fixture.databaseURL
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        var initializationFailed = false
        do {
            _ = try await manager.initializeStorage()
        } catch {
            initializationFailed = true
        }
        await manager.close()

        XCTAssertTrue(initializationFailed)
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: fixture.databaseURL), 2)
        XCTAssertEqual(try intScalar("PRAGMA user_version;", at: fixture.databaseURL), 0)
    }

    func testMalformedPartialStorageSchemaFailsWithoutClaimingCurrentVersion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedMalformedPartialStorageDatabase(at: fixture.databaseURL)
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        do {
            _ = try await manager.initializeStorage()
            XCTFail("Expected malformed storage schema initialization to fail")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }
        await manager.close()

        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: fixture.databaseURL), 1)
        XCTAssertEqual(try intScalar("PRAGMA user_version;", at: fixture.databaseURL), 0)
    }

    func testLegacyEventsTimestampWithoutDefaultFailsAndPreservesData() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyTimestampDefaultDatabase(
            at: fixture.databaseURL,
            timestampDefinition: "TEXT"
        )

        try await assertTimestampDefaultMigrationIsRejected(at: fixture.databaseURL)
    }

    func testLegacyEventsTimestampWithWrongDefaultFailsAndPreservesData() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyTimestampDefaultDatabase(
            at: fixture.databaseURL,
            timestampDefinition: "TEXT DEFAULT('wrong')"
        )

        try await assertTimestampDefaultMigrationIsRejected(at: fixture.databaseURL)
    }

    func testLegacyEventsTimestampWithEquivalentParenthesizedDefaultMigrates() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyTimestampDefaultDatabase(
            at: fixture.databaseURL,
            timestampDefinition: "TEXT DEFAULT ( ( datetime('now') ) )"
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        let readiness = try await manager.initializeStorage()
        await manager.close()

        XCTAssertTrue(readiness.coreReady)
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: fixture.databaseURL), 2)
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM conversation_turns;", at: fixture.databaseURL), 2)
        XCTAssertEqual(
            try intScalar("PRAGMA user_version;", at: fixture.databaseURL),
            StorageSchema.currentVersion
        )
    }

    func testConstraintTextCannotCamouflageMissingStorageChecks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedConstraintCamouflageDatabase(at: fixture.databaseURL)
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        var initializationFailed = false
        do {
            _ = try await manager.initializeStorage()
        } catch {
            initializationFailed = true
        }
        await manager.close()

        XCTAssertTrue(initializationFailed, "Schema verification must exercise actual CHECK constraints")
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: fixture.databaseURL), 1)
        XCTAssertEqual(try intScalar("PRAGMA user_version;", at: fixture.databaseURL), 0)
    }

    func testUnrelatedChecksCannotValidateCamouflagedTargetChecks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedAdversarialConstraintDatabase(at: fixture.databaseURL, scenario: .camouflaged)

        try await assertStorageInitializationRejectsAdversarialConstraints(
            at: fixture.databaseURL,
            demonstrateInvalidValueBypass: true
        )
    }

    func testTargetChecksUsedInsideOrExpressionsAreNotStandaloneConstraints() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedAdversarialConstraintDatabase(at: fixture.databaseURL, scenario: .disjunction)

        try await assertStorageInitializationRejectsAdversarialConstraints(
            at: fixture.databaseURL,
            demonstrateInvalidValueBypass: true
        )
    }

    func testConstraintProbeRejectsSchemaWhenLegalControlIsBlocked() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedAdversarialConstraintDatabase(at: fixture.databaseURL, scenario: .blockedControl)

        try await assertStorageInitializationRejectsAdversarialConstraints(
            at: fixture.databaseURL,
            demonstrateInvalidValueBypass: false
        )
    }

    func testStorageTableConstraintsRejectInvalidCounts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()
        await manager.close()

        XCTAssertThrowsError(
            try execute(
                """
                INSERT INTO event_hourly_rollups(bucket_start, source, event_count)
                VALUES (0, 'fileChanged', -1);
                """,
                at: fixture.databaseURL
            )
        )
        XCTAssertThrowsError(
            try execute(
                """
                INSERT INTO conversation_archives(
                    archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                    turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                    payload_checksum, created_at
                ) VALUES ('a', 's', 1, 1, 'm', 0, 'lzfse', 1, X'00', 1, 'p', 0);
                """,
                at: fixture.databaseURL
            )
        )
    }
}

private extension StorageSchemaTests {
    struct Fixture {
        let directoryURL: URL
        let databaseURL: URL
    }

    enum TestDatabaseError: Error {
        case openFailed(String)
        case statementFailed(String)
        case missingValue
    }

    enum AdversarialConstraintScenario {
        case camouflaged
        case disjunction
        case blockedControl
    }

    func makeFixture() throws -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VitaPet-StorageSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return Fixture(
            directoryURL: directoryURL,
            databaseURL: directoryURL.appendingPathComponent("vitapet.db")
        )
    }

    func seedLegacyDatabase(at databaseURL: URL, includeOptimizedIndex: Bool = false) throws {
        var statements = """
            PRAGMA auto_vacuum = NONE;
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT DEFAULT(datetime('now')),
                source TEXT,
                payload TEXT
            );
            CREATE TABLE conversation_turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                session_id TEXT NOT NULL
            );
            CREATE TABLE ai_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                category TEXT NOT NULL,
                created_at REAL NOT NULL,
                importance INTEGER DEFAULT 1
            );
            INSERT INTO events(timestamp, source, payload) VALUES
                ('2026-07-19 01:00:00', 'fileChanged', '{"path":"/tmp/a"}'),
                ('2026-07-19 02:00:00', 'timer', '{}');
            INSERT INTO conversation_turns(role, content, timestamp, session_id) VALUES
                ('user', 'legacy one', 1, 'session-a'),
                ('assistant', 'legacy two', 2, 'session-a');
            INSERT INTO ai_memories(content, category, created_at, importance)
                VALUES ('legacy memory', 'fact', 1, 2);
            """
        if includeOptimizedIndex {
            statements += """

                CREATE INDEX idx_events_source_timestamp_id ON events(source, timestamp, id);
                """
        }
        try execute(statements, at: databaseURL)
    }

    func seedMalformedPartialStorageDatabase(at databaseURL: URL) throws {
        try execute(
            """
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT DEFAULT(datetime('now')),
                source TEXT,
                payload TEXT
            );
            INSERT INTO events(source, payload) VALUES ('legacy', '{}');
            CREATE TABLE conversation_archives (archive_id TEXT PRIMARY KEY);
            """,
            at: databaseURL
        )
    }

    func seedLegacyTimestampDefaultDatabase(
        at databaseURL: URL,
        timestampDefinition: String
    ) throws {
        try execute(
            """
            PRAGMA auto_vacuum = NONE;
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp \(timestampDefinition),
                source TEXT,
                payload TEXT
            );
            CREATE TABLE conversation_turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                session_id TEXT NOT NULL
            );
            CREATE TABLE ai_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                category TEXT NOT NULL,
                created_at REAL NOT NULL,
                importance INTEGER DEFAULT 1
            );
            INSERT INTO events(id, timestamp, source, payload) VALUES
                (7, '2026-07-18 01:02:03', 'legacy-a', 'payload-a'),
                (9, '2026-07-18 04:05:06', 'legacy-b', 'payload-b');
            INSERT INTO conversation_turns(id, role, content, timestamp, session_id) VALUES
                (3, 'user', 'legacy-turn-a', 11.25, 'session-a'),
                (4, 'assistant', 'legacy-turn-b', 12.5, 'session-a');
            """,
            at: databaseURL
        )
    }

    func assertTimestampDefaultMigrationIsRejected(at databaseURL: URL) async throws {
        let eventsSnapshotSQL = """
            SELECT group_concat(row_snapshot, char(10))
            FROM (
                SELECT quote(id) || '|' || quote(timestamp) || '|' || quote(source)
                    || '|' || quote(payload) AS row_snapshot
                FROM events
                ORDER BY id
            );
            """
        let turnsSnapshotSQL = """
            SELECT group_concat(row_snapshot, char(10))
            FROM (
                SELECT quote(id) || '|' || quote(role) || '|' || quote(content)
                    || '|' || quote(timestamp) || '|' || quote(session_id) AS row_snapshot
                FROM conversation_turns
                ORDER BY id
            );
            """
        let eventsBefore = try textScalar(eventsSnapshotSQL, at: databaseURL)
        let turnsBefore = try textScalar(turnsSnapshotSQL, at: databaseURL)
        let manager = DatabaseManager(databaseURL: databaseURL)

        var initializationFailed = false
        do {
            _ = try await manager.initializeStorage()
        } catch {
            initializationFailed = true
        }
        await manager.close()

        XCTAssertTrue(initializationFailed, "Invalid events.timestamp default must reject migration")
        XCTAssertEqual(try textScalar(eventsSnapshotSQL, at: databaseURL), eventsBefore)
        XCTAssertEqual(try textScalar(turnsSnapshotSQL, at: databaseURL), turnsBefore)
        XCTAssertEqual(try intScalar("PRAGMA user_version;", at: databaseURL), 0)
    }

    func seedConstraintCamouflageDatabase(at databaseURL: URL) throws {
        try execute(
            """
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT DEFAULT(datetime('now')),
                source TEXT,
                payload TEXT DEFAULT 'CHECK (rollup_accounted IN (0, 1))',
                rollup_accounted INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE conversation_turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                session_id TEXT NOT NULL
            );
            CREATE TABLE ai_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                category TEXT NOT NULL,
                created_at REAL NOT NULL,
                importance INTEGER DEFAULT 1
            );
            INSERT INTO events(source, payload) VALUES ('legacy', '{}');
            CREATE TABLE conversation_archives (
                archive_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                first_turn_id INTEGER NOT NULL,
                last_turn_id INTEGER NOT NULL,
                membership_digest TEXT NOT NULL,
                turn_count INTEGER NOT NULL,
                codec TEXT NOT NULL DEFAULT 'CHECK (turn_count > 0)',
                format_version INTEGER NOT NULL,
                compressed_payload BLOB NOT NULL,
                uncompressed_bytes INTEGER NOT NULL,
                payload_checksum TEXT NOT NULL,
                created_at REAL NOT NULL,
                CHECK (first_turn_id <= last_turn_id)
            );
            CREATE TABLE event_hourly_rollups (
                bucket_start INTEGER NOT NULL,
                source TEXT NOT NULL DEFAULT 'CHECK (event_count >= 0)',
                event_count INTEGER NOT NULL,
                PRIMARY KEY (bucket_start, source)
            );
            """,
            at: databaseURL
        )
    }

    func seedAdversarialConstraintDatabase(
        at databaseURL: URL,
        scenario: AdversarialConstraintScenario
    ) throws {
        let eventPayloadDefinition: String
        let archiveCodecDefinition: String
        let rollupSourceDefinition: String
        let eventChecks: String
        let archiveChecks: String
        let rollupChecks: String

        switch scenario {
        case .camouflaged:
            eventPayloadDefinition = "TEXT DEFAULT 'CHECK (rollup_accounted IN (0, 1))'"
            archiveCodecDefinition = "TEXT NOT NULL DEFAULT 'CHECK (turn_count > 0) CHECK (first_turn_id <= last_turn_id)'"
            rollupSourceDefinition = "TEXT NOT NULL DEFAULT 'CHECK (event_count >= 0)'"
            eventChecks = """
                CHECK (source NOT GLOB '__vitapet_storage_check_*')
                /* CHECK (rollup_accounted IN (0, 1)) */
                """
            archiveChecks = """
                CHECK (codec <> 'probe')
                /* CHECK (turn_count > 0) CHECK (first_turn_id <= last_turn_id) */
                """
            rollupChecks = """
                CHECK (source NOT GLOB '__vitapet_storage_check_*')
                /* CHECK (event_count >= 0) */
                """
        case .disjunction:
            eventPayloadDefinition = "TEXT DEFAULT 'CHECK (rollup_accounted IN (0, 1))'"
            archiveCodecDefinition = "TEXT NOT NULL DEFAULT 'CHECK (turn_count > 0) CHECK (first_turn_id <= last_turn_id)'"
            rollupSourceDefinition = "TEXT NOT NULL DEFAULT 'CHECK (event_count >= 0)'"
            eventChecks = """
                CHECK (
                    rollup_accounted IN (0, 1)
                    OR source NOT GLOB '__vitapet_storage_check_*'
                )
                """
            archiveChecks = """
                CHECK (turn_count > 0 OR codec <> 'probe'),
                CHECK (first_turn_id <= last_turn_id OR codec <> 'probe')
                """
            rollupChecks = """
                CHECK (
                    event_count >= 0
                    OR source NOT GLOB '__vitapet_storage_check_*'
                )
                """
        case .blockedControl:
            eventPayloadDefinition = "TEXT"
            archiveCodecDefinition = "TEXT NOT NULL"
            rollupSourceDefinition = "TEXT NOT NULL"
            eventChecks = """
                CHECK (rollup_accounted IN (0, 1)),
                CHECK (source NOT GLOB '__vitapet_storage_check_*')
                """
            archiveChecks = """
                CHECK (turn_count > 0),
                CHECK (first_turn_id <= last_turn_id),
                CHECK (codec <> 'probe')
                """
            rollupChecks = """
                CHECK (event_count >= 0),
                CHECK (source NOT GLOB '__vitapet_storage_check_*')
                """
        }

        try execute(
            """
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT DEFAULT(datetime('now')),
                source TEXT,
                payload \(eventPayloadDefinition),
                rollup_accounted INTEGER NOT NULL DEFAULT 0,
                \(eventChecks)
            );
            CREATE TABLE conversation_turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                session_id TEXT NOT NULL
            );
            CREATE TABLE ai_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                category TEXT NOT NULL,
                created_at REAL NOT NULL,
                importance INTEGER DEFAULT 1
            );
            INSERT INTO events(source, payload) VALUES ('legacy', '{}');
            CREATE TABLE conversation_archives (
                archive_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                first_turn_id INTEGER NOT NULL,
                last_turn_id INTEGER NOT NULL,
                membership_digest TEXT NOT NULL,
                turn_count INTEGER NOT NULL,
                codec \(archiveCodecDefinition),
                format_version INTEGER NOT NULL,
                compressed_payload BLOB NOT NULL,
                uncompressed_bytes INTEGER NOT NULL,
                payload_checksum TEXT NOT NULL,
                created_at REAL NOT NULL,
                \(archiveChecks)
            );
            CREATE TABLE event_hourly_rollups (
                bucket_start INTEGER NOT NULL,
                source \(rollupSourceDefinition),
                event_count INTEGER NOT NULL,
                PRIMARY KEY (bucket_start, source),
                \(rollupChecks)
            );
            """,
            at: databaseURL
        )
    }

    func assertStorageInitializationRejectsAdversarialConstraints(
        at databaseURL: URL,
        demonstrateInvalidValueBypass: Bool
    ) async throws {
        let manager = DatabaseManager(databaseURL: databaseURL)
        var initializationFailed = false
        do {
            _ = try await manager.initializeStorage()
        } catch {
            initializationFailed = true
        }
        await manager.close()

        if !initializationFailed && demonstrateInvalidValueBypass {
            XCTAssertNoThrow(try demonstrateInvalidStorageValuesCanBypassChecks(at: databaseURL))
        }
        XCTAssertTrue(initializationFailed, "Adversarial storage constraints must be rejected")
        if initializationFailed {
            XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: databaseURL), 1)
            XCTAssertEqual(try intScalar("PRAGMA user_version;", at: databaseURL), 0)
        }
    }

    func demonstrateInvalidStorageValuesCanBypassChecks(at databaseURL: URL) throws {
        try execute(
            """
            BEGIN;
            INSERT INTO conversation_archives(
                archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                payload_checksum, created_at
            ) VALUES ('bad-count', 's', 1, 1, 'm', 0, 'lzfse', 1, X'00', 1, 'p', 0);
            INSERT INTO conversation_archives(
                archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                payload_checksum, created_at
            ) VALUES ('bad-range', 's', 2, 1, 'm', 1, 'lzfse', 1, X'00', 1, 'p', 0);
            INSERT INTO event_hourly_rollups(bucket_start, source, event_count)
            VALUES (0, 'fileChanged', -1);
            INSERT INTO events(source, payload, rollup_accounted)
            VALUES ('ordinary', '{}', 2);
            ROLLBACK;
            """,
            at: databaseURL
        )
    }

    func execute(_ sql: String, at databaseURL: URL) throws {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
    }

    func intScalar(_ sql: String, at databaseURL: URL) throws -> Int {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestDatabaseError.missingValue
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func textScalar(_ sql: String, at databaseURL: URL) throws -> String {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawValue = sqlite3_column_text(statement, 0) else {
            throw TestDatabaseError.missingValue
        }
        return String(cString: rawValue)
    }

    func requiredColumnNames(in table: String, at databaseURL: URL) throws -> Set<String> {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare("PRAGMA table_info(\(table));", in: database)
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 1) else { continue }
            names.insert(String(cString: rawName))
        }
        return names
    }

    func columnExists(table: String, column: String, at databaseURL: URL) throws -> Bool {
        try requiredColumnNames(in: table, at: databaseURL).contains(column)
    }

    func indexExists(named name: String, at databaseURL: URL) throws -> Bool {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(name, at: 1, in: statement, database: database)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func indexedColumns(named name: String, at databaseURL: URL) throws -> [String] {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare("PRAGMA index_info(\(name));", in: database)
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 2) else { continue }
            columns.append(String(cString: rawName))
        }
        return columns
    }

    func openDatabase(at databaseURL: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            let message = errorMessage(from: database)
            if let database { sqlite3_close(database) }
            throw TestDatabaseError.openFailed(message)
        }
        return database
    }

    func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
        return statement
    }

    func bind(_ value: String, at index: Int32, in statement: OpaquePointer?, database: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
    }

    func errorMessage(from database: OpaquePointer?) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }
}
