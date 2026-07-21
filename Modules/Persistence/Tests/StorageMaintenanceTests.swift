import Foundation
@testable import Persistence
import SQLite3
import XCTest

final class StorageMaintenanceTests: XCTestCase {
    func testInitializeCapturesLegacyFileEventWatermarkOnlyOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date().timeIntervalSince1970
        try seedLegacyEvents(
            at: fixture.databaseURL,
            events: [(timestamp: now - 7_200, source: "fileChanged")]
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        try await manager.initialize()
        let originalWatermark = try metadataValue(
            for: "file_event_migration_high_watermark",
            at: fixture.databaseURL
        )
        try insertEvent(
            at: fixture.databaseURL,
            timestamp: now - 7_100,
            source: "fileChanged",
            accounted: false
        )
        try await manager.initialize()
        await manager.close()

        XCTAssertEqual(originalWatermark, "1")
        XCTAssertEqual(
            try metadataValue(for: "file_event_migration_high_watermark", at: fixture.databaseURL),
            originalWatermark
        )
        XCTAssertNil(
            try metadataValue(for: "file_event_migration_complete", at: fixture.databaseURL)
        )
    }

    func testTwoDayLegacyFileEventsMoveToCorrectUTCHoursWithoutChangingLogicalCount() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timestamps = [
            now.timeIntervalSince1970 - 2 * 86_400 - 600,
            now.timeIntervalSince1970 - 2 * 86_400 + 3_900,
        ]
        try seedLegacyEvents(
            at: fixture.databaseURL,
            events: timestamps.map { (timestamp: $0, source: "fileChanged") }
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()

        let report = try await manager.performStorageMaintenance(now: now)
        await manager.close()

        XCTAssertEqual(report.rolledUpEventCount, 2)
        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: fixture.databaseURL), 0)
        XCTAssertEqual(
            try intScalar(
                "SELECT COALESCE(SUM(event_count), 0) FROM event_hourly_rollups WHERE source='fileChanged';",
                at: fixture.databaseURL
            ),
            2
        )
        XCTAssertEqual(
            try rollupBuckets(at: fixture.databaseURL),
            Dictionary(grouping: timestamps.map(utcHour), by: { $0 }).mapValues(\.count)
        )
        XCTAssertEqual(
            try metadataValue(for: "file_event_migration_complete", at: fixture.databaseURL),
            "1"
        )
    }

    func testOrdinaryEventsUseThirtyDayRetention() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()
        try insertEvent(
            at: fixture.databaseURL,
            timestamp: now.timeIntervalSince1970 - 2 * 86_400,
            source: "timer",
            accounted: false
        )
        try insertEvent(
            at: fixture.databaseURL,
            timestamp: now.timeIntervalSince1970 - 31 * 86_400,
            source: "timer",
            accounted: false
        )

        let report = try await manager.performStorageMaintenance(now: now)
        await manager.close()

        XCTAssertEqual(report.deletedEventCount, 1)
        XCTAssertEqual(
            try intScalar("SELECT COUNT(*) FROM events WHERE source='timer';", at: fixture.databaseURL),
            1
        )
        XCTAssertEqual(
            try intScalar(
                "SELECT COUNT(*) FROM events WHERE source='timer' AND unixepoch(timestamp)=\(Int64(now.timeIntervalSince1970 - 2 * 86_400));",
                at: fixture.databaseURL
            ),
            1
        )
    }

    func testMaintenanceNeverTouchesUnaccountedFileEventAboveWatermark() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timestamp = now.timeIntervalSince1970 - 2 * 86_400
        try seedLegacyEvents(
            at: fixture.databaseURL,
            events: [(timestamp: timestamp, source: "fileChanged")]
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()
        let aboveWatermarkID = try insertEvent(
            at: fixture.databaseURL,
            timestamp: timestamp,
            source: "fileChanged",
            accounted: false
        )

        _ = try await manager.performStorageMaintenance(now: now)
        await manager.close()

        XCTAssertEqual(
            try intScalar("SELECT COUNT(*) FROM events WHERE id=\(aboveWatermarkID);", at: fixture.databaseURL),
            1
        )
        XCTAssertEqual(
            try intScalar("SELECT COALESCE(SUM(event_count), 0) FROM event_hourly_rollups;", at: fixture.databaseURL),
            1
        )
    }

    func testMaintenanceUsesOneRunEventIDWatermarkAcrossDeletePhases() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()
        try insertEvent(
            at: fixture.databaseURL,
            timestamp: now.timeIntervalSince1970 - 2 * 86_400,
            source: "fileChanged",
            accounted: true
        )
        try execute(
            """
            CREATE TRIGGER insert_old_timer_during_maintenance
            AFTER DELETE ON events
            WHEN OLD.source = 'fileChanged'
            BEGIN
                INSERT INTO events(timestamp, source, payload, rollup_accounted)
                VALUES(datetime(\(now.timeIntervalSince1970 - 31 * 86_400), 'unixepoch'), 'timer', '{}', 0);
            END;
            """,
            at: fixture.databaseURL
        )

        let report = try await manager.performStorageMaintenance(now: now)
        await manager.close()

        XCTAssertEqual(report.deletedEventCount, 1)
        XCTAssertEqual(
            try intScalar("SELECT COUNT(*) FROM events WHERE source='timer';", at: fixture.databaseURL),
            1
        )
    }

    func testHybridSourceAndDailyCountsIncludeRollupsAndLegacyRawButNotRepresentatives() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date().timeIntervalSince1970
        let legacyTimestamp = now - 7_200
        let ordinaryTimestamp = now - 3_600
        let bucket = utcHour(now - 1_800)
        try seedLegacyEvents(
            at: fixture.databaseURL,
            events: [(timestamp: legacyTimestamp, source: "fileChanged")]
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()
        try insertRollup(at: fixture.databaseURL, bucket: bucket, source: "fileChanged", count: 5)
        try insertEvent(
            at: fixture.databaseURL,
            timestamp: now - 1_700,
            source: "fileChanged",
            accounted: true
        )
        try insertEvent(
            at: fixture.databaseURL,
            timestamp: ordinaryTimestamp,
            source: "timer",
            accounted: false
        )

        let bySource = try await manager.fetchEventCountsBySource(days: 7)
        let byDay = try await manager.fetchDailyEventCounts(days: 7)
        await manager.close()

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: bySource.map { ($0.source, $0.count) }), [
            "fileChanged": 6,
            "timer": 1,
        ])

        var expectedByDay: [String: Int] = [:]
        expectedByDay[utcDay(legacyTimestamp), default: 0] += 1
        expectedByDay[utcDay(TimeInterval(bucket)), default: 0] += 5
        expectedByDay[utcDay(ordinaryTimestamp), default: 0] += 1
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: byDay.map { ($0.date, $0.count) }),
            expectedByDay
        )
    }

    func testInvalidLegacyTimestampRollsBackWithoutDeletingRawEvent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        try seedLegacyEvents(at: fixture.databaseURL, events: [])
        try execute(
            """
            INSERT INTO events(timestamp, source, payload)
            VALUES ('2027-01-00 00:00:00', 'fileChanged', '{}');
            """,
            at: fixture.databaseURL
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()

        do {
            _ = try await manager.performStorageMaintenance(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            XCTFail("Expected maintenance to reject a NULL unixepoch conversion")
        } catch {
            // Expected: the event transaction must roll back rather than inventing a bucket.
        }
        await manager.close()

        XCTAssertEqual(try intScalar("SELECT COUNT(*) FROM events;", at: fixture.databaseURL), 1)
        XCTAssertEqual(
            try intScalar("SELECT COUNT(*) FROM event_hourly_rollups;", at: fixture.databaseURL),
            0
        )
    }

    func testMaintenanceDeletesOldBatchMarkersExceptExcludedInFlightBatch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deletedID = UUID()
        let excludedID = UUID()
        let recentID = UUID()
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()
        try insertBatchMarker(
            at: fixture.databaseURL,
            id: deletedID,
            committedAt: now.timeIntervalSince1970 - 8 * 86_400
        )
        try insertBatchMarker(
            at: fixture.databaseURL,
            id: excludedID,
            committedAt: now.timeIntervalSince1970 - 8 * 86_400
        )
        try insertBatchMarker(
            at: fixture.databaseURL,
            id: recentID,
            committedAt: now.timeIntervalSince1970 - 86_400
        )

        _ = try await manager.performStorageMaintenance(
            now: now,
            excludingEventRollupBatchID: excludedID
        )
        await manager.close()

        XCTAssertEqual(try batchMarkerIDs(at: fixture.databaseURL), Set([excludedID, recentID]))
    }

    func testFirstBoundedMaintenancePromotesDeferredIndexAndFeatureGates() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedLegacyEvents(
            at: fixture.databaseURL,
            events: [
                (
                    timestamp: now.timeIntervalSince1970 - 2 * 86_400,
                    source: "fileChanged"
                ),
            ]
        )
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)

        let initial = try await manager.initialize()
        let initialGates = try await manager.currentStorageFeatureGates()
        _ = try await manager.performStorageMaintenance(now: now)
        let promoted = try await manager.currentStorageSchemaReadiness()
        let promotedGates = try await manager.currentStorageFeatureGates()
        await manager.close()

        XCTAssertFalse(initial.optimized)
        XCTAssertFalse(initialGates.schedulerEnabled)
        XCTAssertFalse(initialGates.fullCompactionEnabled)
        XCTAssertTrue(promoted.optimized)
        XCTAssertTrue(promotedGates.schedulerEnabled)
        XCTAssertTrue(promotedGates.fullCompactionEnabled)
        XCTAssertEqual(
            try indexColumns(named: "idx_events_source_timestamp_id", at: fixture.databaseURL),
            ["source", "timestamp", "id"]
        )
    }

    func testFetchStorageMetricsUsesAggregateCountsWithoutDecodingArchives() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()
        try execute(
            """
            INSERT INTO conversation_turns(role, content, timestamp, session_id)
            VALUES ('user', 'one', 1, 'session'), ('assistant', 'two', 2, 'session');
            INSERT INTO conversation_archives(
                archive_id, session_id, first_turn_id, last_turn_id, membership_digest,
                turn_count, codec, format_version, compressed_payload, uncompressed_bytes,
                payload_checksum, created_at
            ) VALUES ('archive', 'session', 3, 5, 'membership', 3, 'invalid-codec', 999,
                      zeroblob(128), 256, 'not-a-real-checksum', 3);
            INSERT INTO events(source, payload, rollup_accounted)
            VALUES ('timer', '{}', 0), ('fileChanged', '{}', 1);
            INSERT INTO event_hourly_rollups(bucket_start, source, event_count)
            VALUES (0, 'fileChanged', 5);
            INSERT INTO event_rollup_batches(batch_id, digest, format_version, committed_at)
            VALUES ('marker', 'digest', 1, 1);
            """,
            at: fixture.databaseURL
        )

        let metrics = try await manager.fetchStorageMetrics()
        await manager.close()

        XCTAssertEqual(metrics.liveConversationTurnCount, 2)
        XCTAssertEqual(metrics.conversationArchiveCount, 1)
        XCTAssertEqual(metrics.archivedConversationTurnCount, 3)
        XCTAssertEqual(metrics.archiveCompressedBytes, 128)
        XCTAssertEqual(metrics.archiveUncompressedBytes, 256)
        XCTAssertEqual(metrics.rawEventCount, 2)
        XCTAssertEqual(metrics.rolledUpEventCount, 5)
        XCTAssertEqual(metrics.eventRollupBatchCount, 1)
        XCTAssertGreaterThan(metrics.databaseBytes, 0)
        XCTAssertGreaterThanOrEqual(metrics.walBytes, 0)
    }

    func testCloseIsTerminalAndPreventsLazyReopen() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let manager = DatabaseManager(databaseURL: fixture.databaseURL)
        try await manager.initialize()

        let firstClose = await manager.close()

        XCTAssertEqual(firstClose, .closed)
        do {
            try await manager.insertEvent(source: "timer", payload: "{}")
            XCTFail("A closed database manager must not lazily reopen its connection")
        } catch DatabaseLifecycleError.closed {
            // Expected terminal lifecycle rejection.
        }
        do {
            _ = try await manager.initialize()
            XCTFail("Initialization after close must not reopen the connection")
        } catch DatabaseLifecycleError.closed {
            // Expected terminal lifecycle rejection.
        }
        let repeatedClose = await manager.close()
        XCTAssertEqual(repeatedClose, .alreadyClosed(previousFailure: nil))
    }

    func testFailedSQLiteCloseRetainsConnectionAndFailureStateForRetry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let closeScript = SQLiteCloseScript(firstResult: SQLITE_BUSY)
        let manager = DatabaseManager(
            databaseURL: fixture.databaseURL,
            sqliteClose: closeScript.close
        )
        try await manager.initialize()

        let firstClose = await manager.close()
        guard case let .failed(failure) = firstClose else {
            return XCTFail("Expected the injected SQLite close failure")
        }
        XCTAssertEqual(failure.resultCode, SQLITE_BUSY)

        do {
            _ = try await manager.fetchStorageMetrics()
            XCTFail("A manager with a failed close must remain terminal")
        } catch let DatabaseLifecycleError.closeFailed(reportedFailure) {
            XCTAssertEqual(reportedFailure, failure)
        }

        let retryClose = await manager.close()
        let repeatedClose = await manager.close()
        XCTAssertEqual(retryClose, .closed)
        XCTAssertEqual(repeatedClose, .alreadyClosed(previousFailure: failure))
    }
}

private final class SQLiteCloseScript: @unchecked Sendable {
    private let lock = NSLock()
    private var firstResult: Int32?

    init(firstResult: Int32) {
        self.firstResult = firstResult
    }

    func close(_ database: OpaquePointer?) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let firstResult {
            self.firstResult = nil
            return firstResult
        }
        return sqlite3_close(database)
    }
}

private extension StorageMaintenanceTests {
    struct Fixture {
        let directoryURL: URL
        let databaseURL: URL
    }

    enum TestDatabaseError: Error {
        case openFailed(String)
        case statementFailed(String)
        case missingValue
    }

    func makeFixture() throws -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitapet-storage-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return Fixture(
            directoryURL: directoryURL,
            databaseURL: directoryURL.appendingPathComponent("vitapet.db")
        )
    }

    func seedLegacyEvents(
        at databaseURL: URL,
        events: [(timestamp: TimeInterval, source: String)]
    ) throws {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT DEFAULT(datetime('now')),
                source TEXT,
                payload TEXT
            );
            """,
            in: database
        )
        for event in events {
            let statement = try prepare(
                "INSERT INTO events(timestamp, source, payload) VALUES(datetime(?, 'unixepoch'), ?, '{}');",
                in: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(event.timestamp, at: 1, in: statement, database: database)
            try bind(event.source, at: 2, in: statement, database: database)
            try step(statement, in: database)
        }
    }

    @discardableResult
    func insertEvent(
        at databaseURL: URL,
        timestamp: TimeInterval,
        source: String,
        accounted: Bool
    ) throws -> Int64 {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(
            """
            INSERT INTO events(timestamp, source, payload, rollup_accounted)
            VALUES(datetime(?, 'unixepoch'), ?, '{}', ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(timestamp, at: 1, in: statement, database: database)
        try bind(source, at: 2, in: statement, database: database)
        guard sqlite3_bind_int(statement, 3, accounted ? 1 : 0) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
        try step(statement, in: database)
        return sqlite3_last_insert_rowid(database)
    }

    func insertRollup(
        at databaseURL: URL,
        bucket: Int64,
        source: String,
        count: Int
    ) throws {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(
            "INSERT INTO event_hourly_rollups(bucket_start, source, event_count) VALUES (?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, bucket) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
        try bind(source, at: 2, in: statement, database: database)
        guard sqlite3_bind_int64(statement, 3, Int64(count)) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
        try step(statement, in: database)
    }

    func insertBatchMarker(at databaseURL: URL, id: UUID, committedAt: TimeInterval) throws {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(
            "INSERT INTO event_rollup_batches(batch_id, digest, format_version, committed_at) VALUES (?, 'digest', 1, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, in: statement, database: database)
        try bind(committedAt, at: 2, in: statement, database: database)
        try step(statement, in: database)
    }

    func metadataValue(for key: String, at databaseURL: URL) throws -> String? {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(
            "SELECT value FROM storage_metadata WHERE key=?;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        case SQLITE_DONE:
            return nil
        default:
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
    }

    func intScalar(_ sql: String, at databaseURL: URL) throws -> Int {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TestDatabaseError.missingValue }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func rollupBuckets(at databaseURL: URL) throws -> [Int64: Int] {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(
            "SELECT bucket_start, event_count FROM event_hourly_rollups WHERE source='fileChanged';",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var result: [Int64: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[sqlite3_column_int64(statement, 0)] = Int(sqlite3_column_int64(statement, 1))
        }
        return result
    }

    func batchMarkerIDs(at databaseURL: URL) throws -> Set<UUID> {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare("SELECT batch_id FROM event_rollup_batches;", in: database)
        defer { sqlite3_finalize(statement) }
        var result = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: raw)) {
            result.insert(id)
        }
        return result
    }

    func indexColumns(named name: String, at databaseURL: URL) throws -> [String] {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare("PRAGMA index_info(\(name));", in: database)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 2) else { continue }
            result.append(String(cString: rawName))
        }
        return result
    }

    func openDatabase(at databaseURL: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            let message = errorMessage(from: database)
            if let database { sqlite3_close(database) }
            throw TestDatabaseError.openFailed(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }

    func execute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
    }

    func execute(_ sql: String, at databaseURL: URL) throws {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        try execute(sql, in: database)
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

    func bind(_ value: TimeInterval, at index: Int32, in statement: OpaquePointer?, database: OpaquePointer?) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
    }

    func step(_ statement: OpaquePointer?, in database: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestDatabaseError.statementFailed(errorMessage(from: database))
        }
    }

    func errorMessage(from database: OpaquePointer?) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }

    func utcHour(_ timestamp: TimeInterval) -> Int64 {
        Int64(floor(timestamp / 3_600) * 3_600)
    }

    func utcDay(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
