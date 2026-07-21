# VitaPet Storage Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Deliver bounded chat/event storage, verified compressed archives, safe periodic reclamation, orderly shutdown, and an operator-visible storage-management UI without touching the user's live database during development or tests.

**Architecture:** Persistence owns schema, archive encoding, idempotent rollup batches, retention, metrics, and compaction. EventBus owns loss-bounded filesystem ingress and a seal/drain barrier without depending on Persistence; the app target wires the two modules through sendable closures and coordinates startup/termination. ChatUI exposes closure-backed storage models so its existing dependency direction remains unchanged.

**Tech Stack:** Swift 6 strict concurrency, SQLite3/WAL, Compression (LZFSE), CryptoKit SHA-256, CoreServices FSEvents, AppKit termination replies, SwiftUI, SwiftPM tests plus temporary-database standalone harnesses.

**Workspace constraint:** This checkout is already a dirty `main` worktree containing the user's and this optimization session's changes, while `.git` is read-only. Preserve all unrelated changes, do not commit/reset/stash, and replace commit steps with `git diff --check` plus focused verification checkpoints.

---

## File map

- `Modules/Persistence/Sources/StoragePolicy.swift`: pure limits, feature gates, and compaction eligibility.
- `Modules/Persistence/Sources/StorageModels.swift`: sendable archive, event-batch, metrics, checkpoint, and maintenance DTOs.
- `Modules/Persistence/Sources/ConversationArchiveCodec.swift`: deterministic canonical JSON, SHA-256, and bounded LZFSE round trips.
- `Modules/Persistence/Sources/DatabaseManager+StorageSchema.swift`: additive verified schema migration and readiness.
- `Modules/Persistence/Sources/DatabaseManager+ConversationArchive.swift`: verify-before-delete archive transactions and archive-aware deletion.
- `Modules/Persistence/Sources/DatabaseManager+EventRollup.swift`: idempotent stable-batch commits, hybrid counts, bounded backfill, and retention.
- `Modules/Persistence/Sources/DatabaseManager+StorageMaintenance.swift`: checkpoint, metrics, capacity checks, full/incremental vacuum, and cancellation hook.
- `Modules/Persistence/Sources/BufferedEventRecorder.swift`: immutable `active`/`inFlight` state machine and coalesced flushes.
- `Modules/Persistence/Sources/StorageMaintenanceCoordinator.swift`: serialized manual/daily maintenance and progress.
- `Modules/Persistence/Sources/PersistenceWriteGate.swift`: synchronous admission, monotonic watermark, seal, and drain.
- `Modules/EventBus/Sources/EventBus.swift`: awaiting publication plus seal/watermark drain.
- `Modules/EventBus/Sources/FileSystemPathClassifier.swift`: component-correct self-storage exclusion.
- `Modules/EventBus/Sources/FileEventIngress.swift`: callback-safe bounded counts/details and one delivery worker.
- `Modules/EventBus/Sources/FSEventsMonitor.swift`: callback batching, overflow flags, injected batch sink, and quiescent stop.
- `Modules/ChatUI/Sources/StorageManagementViewModel.swift`: dependency-neutral UI snapshot/actions.
- `Modules/ChatUI/Sources/StorageManagementSection.swift`: focused storage SwiftUI section.
- `Modules/ChatUI/Sources/SettingsScope.swift`, `SettingsSearchMatcher.swift`, `SettingsView.swift`: storage scope/search/section UI.
- `Modules/ChatUI/Sources/ChatWindowController.swift`: retains and injects one storage view model across settings presentations.
- `App/Sources/StorageManagementAdapter.swift`: maps Persistence reports into ChatUI DTOs without reversing dependencies.
- `App/Sources/AppDelegate.swift`: cutover, scheduling, gated writes, and AppKit termination state machine.
- Focused test files under each module plus `.tmp/StorageLifecycleHarness.swift` for the installed toolchain that cannot import XCTest.

### Task 1: Pure policy, models, and additive core schema

**Files:**
- Create: `Modules/Persistence/Sources/StoragePolicy.swift`
- Create: `Modules/Persistence/Sources/StorageModels.swift`
- Create: `Modules/Persistence/Sources/DatabaseManager+StorageSchema.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager.swift`
- Test: `Modules/Persistence/Tests/StoragePolicyTests.swift`
- Test: `Modules/Persistence/Tests/StorageSchemaTests.swift`

- [x] **Step 1: Write failing policy and migration tests**

```swift
func testCompactionRequiresEveryThreshold() {
    let policy = StoragePolicy.default
    XCTAssertFalse(policy.shouldFullyCompact(databaseBytes: 300 << 20, freePages: 10, pageCount: 100, availableBytes: .max, walBytes: 0))
    XCTAssertTrue(policy.shouldFullyCompact(databaseBytes: 300 << 20, freePages: 30, pageCount: 100, availableBytes: 1 << 30, walBytes: 0))
}

func testInitializeAddsStorageSchemaWithoutDeletingLegacyRows() async throws {
    try seedLegacyEventsAndTurns()
    try await manager.initialize()
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM events"), 2)
    XCTAssertTrue(try columnExists(table: "events", column: "rollup_accounted"))
    XCTAssertTrue(try tableExists("conversation_archives"))
    XCTAssertEqual(try scalar("PRAGMA user_version"), StorageSchema.currentVersion)
}
```

- [x] **Step 2: Run the focused test/harness and verify RED**

Run the Persistence test filter when XCTest is available; otherwise compile the same assertions in `.tmp/StorageLifecycleHarness.swift`. Expected failure: missing `StoragePolicy`, `StorageSchema`, and storage tables.

- [x] **Step 3: Implement exact defaults and verified schema**

```swift
public struct StoragePolicy: Sendable, Equatable {
    public static let `default` = StoragePolicy(
        hotTurnsPerSession: 500, archiveChunkSize: 250,
        fileDetailRetention: 86_400, eventRetention: 2_592_000,
        flushInterval: 30, maintenanceInterval: 86_400,
        fullCompactionMinimumBytes: 256 << 20, fullCompactionFreeRatio: 0.25,
        compactionSafetyBytes: 256 << 20
    )
}

enum StorageSchema {
    static let currentVersion = 2
}
```

`initialize()` must set incremental auto-vacuum before schema creation for a new empty database, create the core tables/indexes in one explicit transaction, add `events.rollup_accounted INTEGER NOT NULL DEFAULT 0` only when absent, verify required columns and indexes with PRAGMA queries, and return a `StorageSchemaReadiness` value. No storage migration may use `try?`.

- [x] **Step 4: Verify GREEN and checkpoint**

Run focused schema/policy assertions, then `git diff --check -- Modules/Persistence`. Expected: every assertion passes and no whitespace errors.

### Task 2: Verified LZFSE conversation archives

**Files:**
- Create: `Modules/Persistence/Sources/ConversationArchiveCodec.swift`
- Create: `Modules/Persistence/Sources/DatabaseManager+ConversationArchive.swift`
- Test: `Modules/Persistence/Tests/ConversationArchiveTests.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager.swift`
- Modify: `App/Sources/AppDelegate.swift`

- [x] **Step 1: Write failing codec/transaction tests**

```swift
func testArchiveRoundTripPreservesUnicodeAndMetadata() throws {
    let turns = [ArchivedConversationTurn(id: 7, role: "assistant", content: "你好 🐾", timestamp: 42, sessionID: "s", petID: "p", petName: "团子")]
    let encoded = try ConversationArchiveCodec.encode(turns)
    XCTAssertEqual(try ConversationArchiveCodec.decode(encoded), turns)
}

func testArchiveKeepsNewestTurnsPerSessionAndIsIdempotent() async throws {
    try seedInterleavedTurns(sessionCounts: ["a": 7, "b": 6])
    let first = try await manager.archiveEligibleConversationTurns(hotLimit: 3, chunkSize: 2)
    let second = try await manager.archiveEligibleConversationTurns(hotLimit: 3, chunkSize: 2)
    XCTAssertEqual(try hotCount("a"), 3)
    XCTAssertEqual(try hotCount("b"), 3)
    XCTAssertEqual(first.archivedTurnCount, 7)
    XCTAssertEqual(second.archivedTurnCount, 0)
    XCTAssertEqual(try decodedArchivedCount(), 7)
}
```

Also test checksum rejection, overlapping-range rejection, stored-BLOB readback, exact affected-row rollback, explicit conversation deletion, and global clear removing archives.

- [x] **Step 2: Verify RED**

Expected failure: missing archive codec/APIs. The interleaved-session test must also demonstrate that the legacy global `deleteOldTurns(keepLast:)` behavior is unsafe.

- [x] **Step 3: Implement canonical archive identity and one non-suspending transaction**

```swift
struct ConversationArchiveEnvelope: Codable, Sendable, Equatable {
    let formatVersion: Int
    let turns: [ArchivedConversationTurn]
}

public struct ConversationArchiveRecord: Sendable, Equatable {
    public let archiveID: String
    public let sessionID: String
    public let firstTurnID: Int64
    public let lastTurnID: Int64
    public let membershipDigest: String
    public let turnCount: Int
    public let payloadChecksum: String
    public let compressedPayload: Data
    public let uncompressedBytes: Int
}
```

Use `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`, SHA-256 for payload/membership/archive identity, and `COMPRESSION_LZFSE`. Inside `DatabaseManager`, run `BEGIN IMMEDIATE`; select the exact oldest eligible IDs per session; reject non-identical overlap; insert-or-verify; read the BLOB and source rows back; decode and compare every field; delete with `session_id = ? AND id IN (...)`; require `sqlite3_changes == turnCount`; then commit. Roll back on every error. Remove the startup call to `deleteOldTurns(keepLast: 100)`.

- [x] **Step 4: Make user deletions archive-aware**

Wrap `deleteConversation(id:)` and `clearConversation()` in transactions that delete `conversation_archives` and hot rows together.

- [x] **Step 5: Verify GREEN and checkpoint**

Run archive tests/harness including mutation checks (corrupt checksum/BLOB and affected-row mismatch must fail), then `git diff --check`.

### Task 3: Idempotent rollup batches and buffered recorder

**Files:**
- Create: `Modules/Persistence/Sources/BufferedEventRecorder.swift`
- Create: `Modules/Persistence/Sources/DatabaseManager+EventRollup.swift`
- Test: `Modules/Persistence/Tests/BufferedEventRecorderTests.swift`
- Test: `Modules/Persistence/Tests/EventRollupTests.swift`

- [x] **Step 1: Write failing stable-batch tests**

```swift
func testSameUUIDAndDigestAcknowledgesWithoutDoubleCounting() async throws {
    let batch = EventRollupBatch.fixture(uuid: fixedUUID, count: 17)
    XCTAssertEqual(try await manager.commitEventRollupBatch(batch), batch.acknowledgement)
    XCTAssertEqual(try await manager.commitEventRollupBatch(batch), batch.acknowledgement)
    XCTAssertEqual(try rollupTotal(), 17)
}

func testSameUUIDWithDifferentDigestIsRejected() async throws {
    _ = try await manager.commitEventRollupBatch(.fixture(uuid: fixedUUID, count: 1))
    await XCTAssertThrowsErrorAsync { try await manager.commitEventRollupBatch(.fixture(uuid: fixedUUID, count: 2)) }
}
```

Recorder tests suspend the database acknowledgement, record later events, and prove `inFlight` never mutates while `active` continues; concurrent flush callers must share one task.

- [x] **Step 2: Verify RED**

Expected failure: missing batch/recorder APIs.

- [x] **Step 3: Implement deterministic immutable batches**

```swift
public struct EventRollupBatch: Sendable, Equatable {
    public let id: UUID
    public let formatVersion: Int
    public let digest: String
    public let buckets: [EventRollupBucket]
    public let representatives: [FileEventRepresentative]
}

public actor BufferedEventRecorder {
    public func record(_ delivery: FileEventDelivery) async
    public func flush() async throws -> EventBatchAcknowledgement?
    public func flushUntilEmpty() async throws
    public func currentInFlightID() -> UUID?
}
```

Canonicalize sorted UTC-hour buckets and sample windows before hashing. Commit marker, rollup upserts, and representative `events` rows (`rollup_accounted = 1`) in one transaction. Existing identical markers return an acknowledgement without reapplying rows; different digest throws. Cap each mutable buffer to 721 hourly buckets and 8,641 detail windows and expose expiry/drop metrics.

- [x] **Step 4: Verify GREEN and checkpoint**

Run deterministic-order, ack-loss retry, concurrent flush, clock rollback, and cap tests; verify no test touches the live application-support database.

### Task 4: Bounded backfill, retention, metrics, and safe reclamation

**Files:**
- Create: `Modules/Persistence/Sources/DatabaseManager+StorageMaintenance.swift`
- Test: `Modules/Persistence/Tests/StorageMaintenanceTests.swift`
- Test: `Modules/Persistence/Tests/StorageCompactionTests.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager+EventRollup.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager.swift`

- [x] **Step 1: Write failing cutoff/watermark and metrics tests**

```swift
func testBackfillAggregatesAndDeletesOnlyExactUnaccountedIDs() async throws {
    let run = StorageRunBoundary(detailCutoff: date24h, retentionCutoff: date30d, eventIDWatermark: 100)
    _ = try await manager.backfillFileEvents(boundary: run, batchLimit: 2)
    XCTAssertEqual(try rollupTotal(), 3)
    XCTAssertEqual(try rawFileEventIDs(), [101])
}

func testHybridCountNeverDoubleCountsAccountedSamples() async throws {
    XCTAssertEqual(try await manager.fetchEventCountsBySource(days: 30).first(where: { $0.source == "fileChanged" })?.count, expectedAcceptedCount)
}
```

Cover ordinary-source retention, 24-hour accounted-detail deletion, >30-day file expiry, complete UTC-hour rollup expiry, seven-day batch-marker cleanup, fixed run watermark, busy checkpoint results, disk-capacity skip, and physical-size reduction on a temporary large DB.

- [x] **Step 2: Verify RED**

Expected failure: raw-only counts and missing bounded maintenance APIs.

- [x] **Step 3: Implement fixed-boundary exact-ID maintenance**

Every changing chunk uses one transaction and selects no more than the policy batch limit. Backfill only `source='fileChanged' AND rollup_accounted=0 AND id<=watermark` inside the retained window, upsert its counts, and delete precisely that selected ID set in the same transaction. Never use a generic timestamp-only prune for `fileChanged`. Replace `fetchEventCountsBySource` with a single-statement hybrid query during migration and rollup-authoritative query after completion.

- [x] **Step 4: Implement checkpoint, metrics, and cancellation-aware compaction**

```swift
public struct StorageMetrics: Sendable, Equatable {
    public let databaseBytes: Int64
    public let walBytes: Int64
    public let pageCount: Int64
    public let freePageCount: Int64
    public let hotTurnCount: Int
    public let archivedTurnCount: Int
    public let rawEventCount: Int
    public let rollupCount: Int
}
```

Read WAL checkpoint `(busy, log, checkpointed)` results. Full compaction requires every policy threshold and enough capacity `>= 2 * (db + wal) + 256 MiB`; install `sqlite3_progress_handler` backed by a lock-safe external cancellation token. Existing `auto_vacuum=0` conversion is `PRAGMA auto_vacuum=INCREMENTAL` then full `VACUUM`, followed by verification, WAL restoration, checkpoint, and new metrics. Later runs use bounded `PRAGMA incremental_vacuum(pageCap)`.

- [x] **Step 5: Remove legacy startup prune and verify GREEN**

Delete the AppDelegate `pruneOldEvents` launch task. Run retention/compaction tests only against temporary URLs, then checkpoint with `git diff --check`.

### Task 5: Filesystem self-exclusion, bounded ingress, and EventBus drain

**Files:**
- Create: `Modules/EventBus/Sources/FileSystemPathClassifier.swift`
- Create: `Modules/EventBus/Sources/FileEventIngress.swift`
- Modify: `Modules/EventBus/Sources/AppEvent.swift`
- Modify: `Modules/EventBus/Sources/EventBus.swift`
- Modify: `Modules/EventBus/Sources/FSEventsMonitor.swift`
- Test: `Modules/EventBus/Tests/FileSystemPathClassifierTests.swift`
- Test: `Modules/EventBus/Tests/FileEventIngressTests.swift`
- Modify: `Modules/EventBus/Tests/EventBusTests.swift`
- Modify: `Modules/EventBus/Tests/FSEventsMonitorTests.swift`

- [x] **Step 1: Write failing exclusion/overflow/drain tests**

```swift
func testExclusionUsesComponentsNotPrefixes() throws {
    let classifier = FileSystemPathClassifier(excludedRoots: [vitaPetRoot])
    XCTAssertTrue(classifier.isExcluded(vitaPetRoot.appendingPathComponent("vitapet.db-wal").path))
    XCTAssertFalse(classifier.isExcluded(vitaPetRoot.deletingLastPathComponent().appendingPathComponent("VitaPetBackup/x").path))
}

func testSealRejectsLatePublishAndDrainWaitsForAcceptedHandler() async {
    let watermark = await bus.seal()
    XCTAssertFalse(await bus.publish(.focusEntered))
    await bus.drain(through: watermark)
}
```

Ingress tests submit a high-rate callback batch and assert all accepted counts survive, plugin details cap at 4,096 distinct path/flag pairs, overflow emits one rescan event, and `stop()` waits for the sole worker.

- [x] **Step 2: Verify RED**

Expected failure: missing classifier/ingress and current `EventBus.publish` returning before handler completion.

- [x] **Step 3: Implement component-safe classification and one-worker ingress**

Resolve symlinks for existing paths; for a deleted path resolve the nearest existing ancestor and append untouched remaining components; compare standardized `pathComponents`. The FSEvents callback submits a whole callback batch synchronously to a lock-protected bounded accumulator and creates no `Task`. One tracked worker hands count/sample snapshots to an injected async sink and publishes representative plugin events. Surface dropped/must-scan flags via a new explicit `.fileSystemRescanRequired(droppedDetailCount:)` event.

- [x] **Step 4: Implement awaiting publish plus seal/watermark drain**

```swift
@discardableResult public func publish(_ event: AppEvent) async -> Bool
public func seal() -> UInt64
public func drain(through watermark: UInt64) async
```

Snapshot matching handlers, execute them in a task group owned by the publish call, and advance a contiguous completed-sequence watermark. `seal()` rejects later publications but allows accepted handlers to finish. Existing call sites continue using `await eventBus.publish(...)`.

- [x] **Step 5: Verify GREEN and checkpoint**

Run pure ingress/classifier/bus harnesses and the existing FSEvents integration test when supported; scan `FSEventsMonitor.swift` to prove the callback body contains no `Task`.

### Task 6: Maintenance coordinator and persistence write gate

**Files:**
- Create: `Modules/Persistence/Sources/StorageMaintenanceCoordinator.swift`
- Create: `Modules/Persistence/Sources/PersistenceWriteGate.swift`
- Test: `Modules/Persistence/Tests/StorageMaintenanceCoordinatorTests.swift`
- Test: `Modules/Persistence/Tests/PersistenceWriteGateTests.swift`

- [x] **Step 1: Write failing serialization/gate tests**

```swift
func testConcurrentMaintenanceCallsShareOneRun() async throws {
    async let a = coordinator.runNow()
    async let b = coordinator.runNow()
    XCTAssertEqual(try await a.runID, try await b.runID)
    XCTAssertEqual(await probe.maximumConcurrentRuns, 1)
}

func testSealWaitsThroughAdmittedWatermarkAndRejectsLateWrites() async throws {
    let task = try gate.submit { await latch.wait(); return 42 }
    let watermark = gate.seal()
    XCTAssertThrowsError(try gate.submit { 0 })
    await latch.open()
    await gate.wait(through: watermark)
    XCTAssertEqual(try await task.value, 42)
}
```

- [x] **Step 2: Verify RED**

Expected failure: missing coordinator/gate.

- [x] **Step 3: Implement independent feature gates and scheduled/manual runs**

```swift
public struct StorageFeatureGates: Sendable, Equatable {
    public var retentionEnabled: Bool
    public var fullCompactionEnabled: Bool
    public var schedulerEnabled: Bool
}
```

Only one run task exists. Manual runs respect retention/compaction gates; scheduler only controls invocation. Each run flushes recorder, archives, backfills/deletes, cleans markers, checkpoints, measures, optionally compacts, records the result, and returns user-readable skip reasons. Scheduling occurs no more than once per 24 hours.

- [x] **Step 4: Implement synchronous write admission**

Use `NSLock` to reserve an increasing sequence and insert it into the unfinished set before constructing the returned `Task<T, Error>`. Completion removes the sequence and resumes only waiters whose watermark has no unfinished predecessor. `seal()` is synchronous and idempotent; later submissions throw `PersistenceWriteGateError.closed`.

- [x] **Step 5: Verify GREEN and checkpoint**

Run gate races repeatedly, coordinator feature-gate matrix tests, and cancellation tests.

### Task 7: App startup cutover, periodic scheduling, and orderly AppKit termination

**Files:**
- Modify: `App/Sources/AppDelegate.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager.swift`
- Test: `.tmp/OrderlyTerminationHarness.swift`

- [x] **Step 1: Write a failing integration harness around a factored termination pipeline**

```swift
let result = await pipeline.terminate()
precondition(probe.steps == [
    .maintenanceCancelled, .sourcesStopped, .busDrained,
    .recorderFlushed, .ownersCancelled, .writesDrained,
    .databaseCheckpointed, .databaseClosed, .lockReleased, .replied
])
precondition(result.replyCount == 1)
```

Also test repeated Quit requests, late write rejection, retryable close, nonretryable close, watchdog marker, and attempted reopen after closing.

- [x] **Step 2: Verify RED**

Expected failure: current `applicationWillTerminate` launches unawaited cleanup and releases the lock before source/database drain.

- [x] **Step 3: Wire safe file-event cutover and all storage owners**

After verified core schema, create the recorder/coordinator/gate, pause only legacy file-change persistence, drain its admitted writes, capture the migration high watermark, then construct `FSEventsMonitor(paths:[home], excludedRoots:[VitaPet application-support root], onDelivery: recorder.record)`. If cutover fails, disable file-change persistence for the launch but keep plugin delivery and low-frequency persistence.

Route chat callback, low-frequency `recordEvent`, conversation updates/deletes, pet-state writes, and other fire-and-forget database mutations through `PersistenceWriteGate`. Keep read operations directly awaited on `DatabaseManager`.

- [x] **Step 4: Replace termination callback with one idempotent state machine**

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    terminationTask = Task { @MainActor [weak self] in await self?.finishTermination() }
    return .terminateLater
}
```

Stop/cancel in the specified order, seal and drain EventBus, flush recorder, cancel owners, seal/drain writes, checkpoint/close, then release the single-instance lock immediately before exactly one `NSApp.reply(toApplicationShouldTerminate:)`. A global watchdog writes an excluded lifecycle marker with the last durable stage and still replies once so Quit cannot hang. `applicationWillTerminate` must not launch cleanup work.

- [x] **Step 5: Start daily maintenance and verify GREEN**

Start scheduling only after bootstrap settles. Run the termination harness, event routing harness, and full product build; inspect for remaining database fire-and-forget tasks outside the gate.

### Task 8: Storage management UI

**Files:**
- Create: `Modules/ChatUI/Sources/StorageManagementViewModel.swift`
- Create: `Modules/ChatUI/Sources/StorageManagementSection.swift`
- Test: `Modules/ChatUI/Tests/StorageManagementViewModelTests.swift`
- Modify: `Modules/ChatUI/Sources/SettingsScope.swift`
- Modify: `Modules/ChatUI/Sources/SettingsSearchMatcher.swift`
- Modify: `Modules/ChatUI/Sources/SettingsView.swift`
- Modify: `Modules/ChatUI/Sources/ChatWindowController.swift`
- Create: `App/Sources/StorageManagementAdapter.swift`
- Modify: `App/Sources/AppDelegate.swift`

- [x] **Step 1: Write failing UI-model/search tests**

```swift
func testRefreshAndManualMaintenanceExposeBusySuccessAndFailure() async {
    let model = StorageManagementViewModel(load: loadSnapshot, maintain: runMaintenance)
    await model.refresh()
    XCTAssertEqual(model.snapshot?.hotTurnCount, 500)
    await model.runMaintenance()
    XCTAssertFalse(model.isRunning)
    XCTAssertNotNil(model.lastMessage)
}

func testStorageTermsFindStorageSection() {
    XCTAssertEqual(SettingsSearchMatcher.visibleSections(selectedScope: .all, query: "压缩"), [.storageManagement])
}
```

- [x] **Step 2: Verify RED**

Expected failure: missing storage section/model.

- [x] **Step 3: Implement dependency-neutral UI contract**

```swift
public struct StorageManagementSnapshot: Sendable, Equatable {
    public let databaseBytes: Int64
    public let walBytes: Int64
    public let hotTurnCount: Int
    public let archivedTurnCount: Int
    public let rawEventCount: Int
    public let rollupCount: Int
    public let reclaimableBytes: Int64
    public let policySummary: String
    public let lastMaintenanceSummary: String?
}
```

The view model receives `@Sendable` async load/run closures, so ChatUI does not import Persistence. Add a “存储” scope and “存储管理” section showing formatted sizes/counts, last result, policy summary, recoverable errors, and a disabled-progress “立即整理” button. Refresh asynchronously on appearance and after maintenance without blocking the settings window. Add Chinese/English search terms including 存储、空间、整理、压缩、归档、数据库、storage、compact、archive.

- [x] **Step 4: Wire through `ChatWindowController` and AppDelegate**

Construct one `StorageManagementViewModel` in `StorageManagementAdapter.makeViewModel(databaseManager:coordinator:)`, inject it into `ChatWindowController`, retain it across repeated `showSettings()` calls, and map Persistence metrics/reports into ChatUI DTOs only in the app target.

- [x] **Step 5: Verify GREEN and checkpoint**

Run UI-model/search harness, strict ChatUI build, and inspect SettingsView bindings/action state.

### Task 9: Final integration, mutation checks, and delivery audit

**Files:**
- Create/modify: `.tmp/StorageLifecycleHarness.swift`
- Create/modify: `.tmp/OrderlyTerminationHarness.swift`
- Review: all files above and `docs/superpowers/specs/2026-07-17-storage-lifecycle-design.md`

- [x] **Step 1: Run temporary-database end-to-end lifecycle test**

Seed multiple conversations and legacy/new file events into a temp DB; initialize/migrate; archive; ingest/retry a stable batch; backfill; retain; checkpoint; compact a synthetic large DB; reopen; decode archives; and verify logical event totals and deletion semantics.

- [x] **Step 2: Prove regression tests are meaningful**

Temporarily mutate or disable archive checksum verification, UUID/digest mismatch rejection, self-path exclusion, and termination drain one at a time; each corresponding harness must fail. Restore production code and rerun to PASS.

- [x] **Step 3: Run full verification**

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
CLANG_MODULE_CACHE_PATH=$PWD/.tmp/clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.tmp/swiftpm-module-cache \
swift build --disable-sandbox --product VitaPetApp \
  -Xswiftc -I -Xswiftc $PWD/.tmp/sdk-overlay
```

Then run every standalone harness, `git diff --check`, and a targeted scan proving no startup `deleteOldTurns`/`pruneOldEvents`, no Task in the FSEvents callback, and no untracked termination cleanup.

- [x] **Step 4: Two-stage review and requirement audit**

Dispatch a spec-compliance reviewer against every design section, then a code-quality/concurrency/data-safety reviewer. Resolve all Critical/Important findings and rerun the affected tests plus full build. Document any environment-only XCTest limitation exactly; do not extrapolate from a partial run.
