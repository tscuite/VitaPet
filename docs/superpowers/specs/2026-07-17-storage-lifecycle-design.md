# VitaPet Storage Lifecycle Design

## Goal

Keep VitaPet's chat history recoverable while preventing the application database from growing without bound or causing background I/O hitches.

This design covers future write amplification, periodic retention, compressed chat archives, database-space reclamation, and a small storage-management surface. It does not modify the user's current database until the maintenance implementation has passed round-trip and migration tests.

## Measured Baseline

The current user database at `~/Library/Application Support/VitaPet/vitapet.db` is approximately 2.0 GB.

- `conversation_turns`: 100 rows and about 10 KB of message text.
- `events`: 2,375,537 rows and about 379 MB of JSON payload text.
- `fileChanged`: 2,281,145 event rows, which is over 96% of raw events.
- SQLite free list: 408,250 of 530,317 pages. At 4,096 bytes per page, roughly 1.56 GB is already free inside the database but has not been returned to the filesystem.
- Journal mode is WAL and `auto_vacuum` is currently disabled.
- The filesystem monitor watches the entire home directory, including VitaPet's own Application Support directory. Database/WAL writes can therefore create new `fileChanged` events and form a write-amplifying feedback loop.
- Startup currently calls `deleteOldTurns(keepLast: 100)`, whose SQL retains only 100 turns globally rather than per conversation. This unsafe legacy pruning conflicts with recoverable per-conversation archives and must be disabled before rollout.

The primary problem is therefore high-frequency event ingestion plus unreclaimed SQLite pages, not chat text volume. A chat-only compressor would not materially improve the present 2.0 GB footprint.

## Considered Approaches

### 1. Archive chat, aggregate activity, and reclaim pages — selected

Keep recent chat rows directly queryable, compress older rows into verified archives, sample high-frequency activity details while preserving aggregate counts, then reclaim free database pages during scheduled maintenance.

This preserves user-authored content, retains meaningful 7-day and 30-day statistics, and fixes both future growth and the existing oversized file.

### 2. Hard retention limits

Delete chat rows beyond a fixed per-conversation count and delete all activity details beyond seven days. This is much simpler, but it irreversibly discards user-authored conversation history.

### 3. VACUUM only

Run periodic `VACUUM` without changing ingestion or retention. This would recover the current free pages temporarily, but the database would grow back because `fileChanged` continues to generate millions of rows.

## Selected Architecture

The implementation is split into five independently testable components.

### StoragePolicy

A pure value type defines the default policy:

- Keep the newest 500 chat turns per conversation in the hot `conversation_turns` table.
- Archive older turns in chunks of up to 250 rows.
- Keep ordinary raw activity events for 30 days.
- Keep detailed `fileChanged` samples for 24 hours.
- Preserve file-change counts in UTC hourly rollups for 30 days.
- Attempt to flush buffered high-frequency counts every 30 seconds and on orderly app termination; durability advances only when SQLite acknowledges an immutable batch.
- Run lightweight maintenance no more than once per 24 hours.
- Run a full compaction only when the database is larger than 256 MB, at least 25% of its pages are free, and the volume has enough temporary capacity.

These defaults are constants in the first version. A settings editor for every threshold is intentionally out of scope; the management UI explains the active policy and offers a manual maintenance action.

### ConversationArchiveStore

Before archive schema activation, startup stops calling the legacy global `deleteOldTurns(keepLast:)`. The replacement retention query partitions by `session_id`; no global turn limit remains. This prerequisite ships independently and is covered with interleaved turn IDs from multiple sessions so one busy conversation can never delete another conversation's history.

Older chat turns are serialized in chronological order and compressed with Apple's LZFSE codec. Archives live in a new SQLite table so archive creation and hot-row deletion can be transactional.

Each archive records:

- a deterministic archive ID derived from the session, ordered source IDs, format version, and canonical-payload checksum;
- session ID;
- first and last source turn IDs;
- a digest of the complete ordered source-ID membership, not only the range endpoints;
- turn count;
- codec/version identifier;
- compressed payload;
- uncompressed byte count;
- SHA-256 checksum of the canonical uncompressed payload;
- informational creation timestamp, which is written only for the first insertion and is excluded from archive identity/equivalence.

Archiving follows a verify-before-delete transaction:

1. Select an eligible chronological chunk below the hot retention boundary.
2. Canonically encode every source field, calculate the ordered-ID membership digest and payload checksum, then compress it.
3. Reject any existing archive for the same session whose ID range overlaps this chunk unless it has the same deterministic archive ID and identical metadata.
4. Insert the archive, or recognize an already stored byte-identical archive as an idempotent retry.
5. Select the stored row back from SQLite, re-select the source rows, decode the bound BLOB and metadata, and verify the canonical bytes, checksum, codec/version, byte count, ordered IDs, first/last IDs, row count, roles, content, timestamps, and pet metadata against the still-current source rows.
6. Delete only `conversation_turns` rows matching both the session ID and the exact verified ID set.
7. Require SQLite's affected-row count to equal the archive turn count; otherwise roll back.
8. Commit.

The overlap check, insert-or-identical retry, SQLite read-back, source-row revalidation, exact deletion, affected-row check, and commit execute inside one non-suspending `DatabaseManager` actor method; no `await` is permitted while its SQLite transaction is open. Any failure rolls back the archive insertion and source deletion together. A unique deterministic archive ID plus an overlap check prevents duplicate or overlapping archives; endpoint uniqueness alone is not considered sufficient. Re-running maintenance either verifies the identical stored archive and finishes its exact deletion or creates one new archive. When an identical archive already exists, its stored creation timestamp is preserved and ignored by the identity comparison; all content-bearing metadata and bytes must still match.

The store exposes archive listing and decompression APIs so records remain recoverable and exportable. Automatic loading of years of archived messages into the live chat view is not part of this pass; the current UI only loads the newest 50 messages, and preserving that bounded hot path is important for responsiveness.

Deleting a conversation explicitly deletes its hot turns and compressed archives in the same transaction. The existing global clear operation does the same, so a user-requested deletion does not leave hidden archive data behind.

### BufferedEventRecorder

Low-frequency events continue to use the existing raw `events` table. `fileChanged` is routed through a small actor-owned buffer:

- the event source rejects the VitaPet Application Support root itself and every descendant before publishing to the event bus, using standardized path components rather than string prefixes; existing paths are symlink-resolved, while deleted paths resolve their nearest existing ancestor and append the remaining components;
- every accepted change increments an in-memory UTC-hour/source count;
- at most one representative raw detail row is retained per 10-second window measured by a monotonic clock;
- a monotonic clock also schedules 30-second flush attempts, while UTC wall time is used only to choose hourly rollup buckets and retention cutoffs;
- an orderly-termination barrier stops sources, drains accepted events, and durably flushes the final batch before AppKit is allowed to terminate.

The high-frequency persistence path does not travel through the current callback -> EventBus-handler -> `recordEvent` chain, which creates three untracked tasks per notification. The FSEvents callback hands each callback batch to a source-owned bounded ingress. Before any representative-event coalescing, a lock-protected bounded accumulator synchronously folds every accepted callback record into UTC-hour counts and the current monotonic sampling window. It retains at most the policy window plus one current partial bucket: 721 UTC hourly buckets for 30-day counts and 8,641 sampling windows for 24-hour detail. Older entries expire with an explicit policy-expiry metric rather than growing memory indefinitely. One tracked worker transfers immutable accumulator snapshots to `BufferedEventRecorder` and drains path-level representatives through an awaiting EventBus API for plugins.

The representative queue holds at most 4,096 distinct path/flag entries. Duplicate entries coalesce. Once full, persistence counts continue, while additional path details increment `droppedDetailCount` and set `needsRescan`; after capacity returns, the worker publishes one explicit overflow/rescan event before later representatives. FSEvents `UserDropped`, `KernelDropped`, and `MustScanSubDirs` flags set the same state. Plugin `fileChanged` triggers are therefore best-effort representatives during overload, never silently promised as a lossless operation stream. Source stop closes this ingress and awaits its sole worker; it does not return while a callback can still enqueue.

This reduces file-change detail rows from an unbounded burst rate to at most 8,640 samples per day while preserving the count of accepted FSEvents callback records in acknowledged batches. That count is not a guarantee of the number of physical filesystem operations. The actor performs no UI work and a database flush produces one transaction rather than one task and SQLite insert per filesystem notification.

The additive event migration includes a `rollup_accounted` flag. Existing rows begin unaccounted; new representative detail samples are marked accounted because their true count already entered the buffer.

The recorder is an explicit two-buffer state machine. `active` remains mutable and accepts new events. At flush time the actor atomically swaps it for an immutable `inFlight` value containing a new UUID, format version, canonical payload digest, sorted bucket counts, and representative samples; a fresh `active` immediately receives later events even while database I/O is suspended. The digest is calculated from deterministic bytes and never from dictionary iteration order. Until commit acknowledgement, every retry sends exactly the same UUID, digest, counts, and samples. The database transaction inserts `(uuid, digest)` into `event_rollup_batches`, upserts counts and samples only when the UUID is new, and commits. An existing UUID with the same digest is an acknowledgement retry; an existing UUID with a different digest is a data-integrity error and never silently succeeds.

Timer, manual, and termination flush requests share at most one tracked `flushTask`; later requests await it rather than opening a second database submission. The acknowledgement returns UUID plus digest, and the actor clears `inFlight` only when both match its current immutable batch. It then may swap the next non-empty `active`. An in-memory recorder never retries a batch across process restarts.

The source accumulator, recorder `active`, and recorder `inFlight` are separately capped at 721 hourly buckets and 8,641 representative windows. `inFlight` is never mutated or expired while retryable; `active` and the source accumulator apply rolling policy expiry as new data arrives. The file-change pipeline therefore has a hard process-wide payload cap of 2,163 bucket entries and 25,923 representative-window entries, plus the separate 4,096-entry plugin-detail queue and constant bookkeeping. Reaching a cap cannot mutate `inFlight`; it expires only policy-out-of-window data from mutable buffers and reports that count.

Each maintenance run fixes one `detailCutoff`, one `retentionCutoff`, and one event-ID watermark before changing rows. For the 24-hour-to-30-day retained window, a transaction selects one bounded set of `fileChanged` IDs below `detailCutoff`, aggregates only selected unaccounted rows into UTC-hour buckets, and deletes exactly the selected rows: accounted samples are not aggregated because their counts already came through a stable recorder batch. Inside the retained interval, an unaccounted row may be deleted only by the same transaction that aggregates it. Rows strictly older than `retentionCutoff` are policy-expired and may be deleted in bounded exact-ID transactions without first creating rollups that would immediately expire. Every deletion is source-qualified and below the run's fixed ID watermark; a generic timestamp-only delete is forbidden.

Cutover from legacy raw file-change writes is ordered and fail-closed. The app pauses only `fileChanged` persistence while path-level plugin delivery continues, seals and drains the legacy file-change write watermark, then runs one non-suspending database transaction that verifies the required core schema, records the legacy maximum event ID as the migration high watermark, and commits the backfill state. Only after that commit does the source enable buffered ingestion whose representative rows are born accounted. This ordering forbids any unaccounted `fileChanged` row above the high watermark. If schema verification or cutover fails, the state becomes storage-degraded: new `fileChanged` persistence is disabled for that launch, existing rows are untouched, plugin delivery and low-frequency event persistence continue, the UI reports the failure, and the app never falls back to the legacy per-event database path. A later startup may retry the idempotent cutover.

While legacy backfill remains incomplete, `fileChanged` count queries add committed rollups to raw rows in the same interval where `rollup_accounted = 0` and `id <= migrationHighWatermark`; accounted representative samples are detail only and are excluded from totals. The hybrid result is produced by one SQL statement or one non-suspending read transaction in `DatabaseManager`, never two awaited reads around a possible backfill commit. Because aggregation and exact source-row deletion share one transaction, readers see either the old raw contribution or the new rollup contribution, never both or neither. The migration-complete marker is committed only after no unaccounted retained `fileChanged` row remains at or below the persisted migration high watermark. After that marker, rollups become the authoritative total and raw rows remain recent detail samples only. Existing raw-only count APIs are forbidden for `fileChanged` during and after migration. For other sources, count queries continue to use raw rows. The generic file-change trend is explicitly defined in whole UTC hours after the 24-hour raw-detail window; it is not presented as second-precise. Existing mood, pet behavior, click, interaction, and game statistics retain their current query semantics and 30-day raw history; changing UTC/local-calendar behavior is a separate non-goal.

### StorageMaintenanceCoordinator

The coordinator runs after startup work has settled, then at most once every 24 hours when scheduling is enabled. It is also callable manually from settings. Only one maintenance run may execute at a time. Independent feature gates control bounded retention, full compaction, and automatic scheduling; enabling one never implicitly enables another. `retentionEnabled` gates archive, destructive backfill, raw-detail expiry, ordinary-event expiry, and rollup expiry as one fail-closed phase. Batch-marker housekeeping may run independently. Manual maintenance never bypasses retention or compaction gates; `schedulerEnabled` controls invocation only.

The ordered maintenance flow is (steps that change rows use explicit transactions; checkpoint and vacuum run outside them):

1. Capture fixed UTC detail/retention cutoffs and an event-ID watermark, then flush the recorder's current immutable batch.
2. Archive eligible conversation turns when bounded retention is enabled.
3. Backfill the 24-hour-to-30-day file-change window in bounded exact-ID transactions.
4. Delete bounded sets of `fileChanged` rows older than 30 days without aggregation, and delete only accounted `fileChanged` detail rows older than 24 hours outside the current backfill set.
5. Delete ordinary raw events older than 30 days and delete only complete UTC hourly-rollup buckets whose `bucketEnd <= fixedRetentionCutoff`.
6. Delete acknowledged batch markers whose committed-at timestamp is older than the fixed seven-day retry cutoff, excluding the recorder's current `inFlight` UUID.
7. Checkpoint and truncate the WAL, reading SQLite's `busy`, log-page, and checkpointed-page result.
8. Inspect page count, free-list count, database size, WAL size, and available volume capacity.
9. Compact only if the separate full-compaction gate and policy thresholds allow.

For a new database, incremental auto-vacuum is enabled before schema creation. For an existing database with auto-vacuum disabled, the first eligible full compaction runs only when the checkpoint reports `busy == 0`, every prepared statement is finalized, no transaction is active, and available capacity is at least twice the current database-plus-WAL size plus a 256 MB safety margin. The actor executes `PRAGMA auto_vacuum = INCREMENTAL` followed by a full `VACUUM`, verifies `PRAGMA auto_vacuum == 2`, verifies or restores WAL journal mode, checkpoints again, and records post-compaction page/file metrics. Later maintenance calls `incremental_vacuum` with both a page cap and a time/cancellation budget. Every incremental run is followed by another checkpoint; its busy/log/checkpointed results, database/WAL sizes, page count, and free-list count are measured before success is reported.

Long SQLite operations install a progress handler that reads a thread-safe cancellation token whose setter does not require entering the busy `DatabaseManager` actor; controlled `sqlite3_interrupt` is an allowed fallback for the single owned connection. This applies to full/incremental vacuum and index creation. Ordinary bounded transactions stop between chunks and either complete or roll back the current chunk; they do not promise mid-statement interruption.

Schema readiness has two explicit phases. `coreReady` verifies every table, column, constraint, and small index required for correct ingestion, hybrid queries, archive transactions, and retention; it is sufficient to open the safe ingestion/retention gates. `optimized` additionally verifies the large `(events.source, events.timestamp, events.id)` index. New databases create that index immediately. A large existing database records it as deferred, performs the first bounded rollup/delete pass under `coreReady`, then builds and verifies the index against the smaller table. Index failure leaves `optimized = false` and reports degraded query performance but does not invalidate the already verified data schema or re-enable legacy pruning; automatic scheduling/full compaction remain disabled until the operator-visible retry succeeds. The smaller `(conversation_turns.session_id, conversation_turns.id)` index belongs to `coreReady`.

All SQLite work remains inside `DatabaseManager`, which is already an actor. Compaction can delay database writes but does not execute on the main actor. The coordinator reports progress and never runs two SQLite maintenance operations concurrently.

### Orderly Termination Barrier

All asynchronous mutations outside the specialized file-change recorder go through a `PersistenceWriteGate`. Its synchronous submission point assigns a monotonic sequence and registers a tracked task before returning; callers that need a result await the returned task. Sealing the gate returns the last admitted watermark, later submissions fail with a closed error, and shutdown can await every admitted write at or below the watermark. Existing fire-and-forget database tasks in AppDelegate and AI conversation callbacks are converted to this gate or to owner-tracked structured tasks. `DatabaseManager` itself has explicit open/closing/closed/closeFailed states: closing rejects new operations, `close` propagates `sqlite3_close` failures without discarding a still-live pointer, and neither terminal state permits lazy reopen.

`applicationWillTerminate` cannot launch unawaited cleanup and assume it finishes. The app instead implements one idempotent `applicationShouldTerminate` state machine. Repeated termination requests share the same task and can produce only one AppKit reply. The first request returns `.terminateLater` while it:

1. cancels scheduled maintenance and requests interruption of a running bounded transaction or vacuum; no new archive, retention, or compaction work may start;
2. stops every source and awaits source-specific callback quiescence; the FSEvents callback yields into a source-owned serial stream instead of creating untracked tasks, and source stop waits for its delivery worker;
3. seals EventBus ingress, records the last accepted sequence watermark, and awaits completion of every handler at or below that watermark; `EventBus.publish` no longer creates untracked handler tasks;
4. closes recorder intake only after the bus watermark is drained, then commits the existing immutable `inFlight` batch followed by successive immutable swaps of any remaining `active` data;
5. cancels and awaits AI/chat/background task owners that can submit persistence work, seals `PersistenceWriteGate`, and waits through its admitted watermark;
6. checkpoints and closes the database actor;
7. releases the single-instance lock and calls `NSApp.reply(toApplicationShouldTerminate:)` exactly once.

Each event source must define what “stopped” means and may not leave untracked delivery tasks behind. EventBus rejects publication only after all sources are quiescent. A running full or incremental vacuum installs the external cancellation/progress hook; termination requests interruption and waits for SQLite to return before close, subject to the global watchdog.

If `sqlite3_close` returns `SQLITE_BUSY` or `SQLITE_LOCKED`, the manager retains the pointer in `closeFailed`, finalizes any remaining owned statements, and retries close until the same global watchdog; all APIs continue rejecting new work. Any other non-OK result takes the unclean branch immediately. Success transitions to `closed`. On success, the app releases the single-instance lock immediately before its one clean `reply(true)`. On a nonretryable error or retryable failure that reaches the watchdog, the app atomically writes an excluded lifecycle marker containing the SQLite result and last acknowledged durability stage, marks the shutdown unclean, then releases the lock immediately before one `reply(true)` so Quit cannot hang indefinitely. It never reports a clean close or reopens the connection; a still-live pointer is left for process teardown. The next startup surfaces that state and retries only safe idempotent work; it never claims the prior drain completed.

## Storage Management UI

Settings receives a compact “存储管理” section that shows:

- database and WAL file sizes;
- hot and archived chat-turn counts;
- raw event and rollup counts;
- estimated reclaimable database space;
- last successful maintenance time and result;
- the active retention/archive policy;
- a guarded “立即整理” action.

The action starts maintenance asynchronously and displays success, skipped-compaction reasons, or a recoverable error. It does not freeze the settings window. No automatic “clear all” action is added; existing conversation deletion remains the explicit destructive operation.

## Failure Handling and Data Safety

- Chat source rows are never deleted until the archive has been inserted, selected back from SQLite, decoded, and matched byte-for-byte and field-for-field in the same transaction; the exact session-qualified deletion count must also match.
- Existing databases are migrated additively. Migration uses an explicit schema version plus phased `PRAGMA table_info`/index verification; it never ignores `ALTER TABLE` failures with `try?`. A partial or unverifiable core migration leaves file-change ingestion, retention, and compaction gates closed; a deferred large-index state follows the separate `coreReady`/`optimized` rules above. Migration and maintenance are separate, so opening a new app version does not immediately rewrite a 2 GB database.
- The existing unbounded startup `pruneOldEvents` call is disabled before rollup schema activation. Until a migration-complete marker exists, no generic timestamp prune may delete `fileChanged`; only the bounded source-aware transactions above may remove it. Migration errors fail closed and retain raw rows.
- Full compaction is skipped when temporary disk capacity is insufficient.
- Cancellation before deletion leaves source rows intact. Maintenance installs a SQLite progress/cancellation hook for vacuum, waits for SQLite to return, and reports whether it completed or rolled back.
- A failed rollup leaves raw event rows intact and can be retried.
- Thirty seconds is a healthy-operation flush target, not a hard loss bound. A crash, forced kill, persistent busy state, write failure, or watchdog expiry can lose in-memory events accumulated since the last acknowledged batch; the UI/log reports that boundary. Under a healthy database, a normal Quit waits for accepted event work and all recorder buffers to commit. A persistent on-disk event outbox would be required for a hard loss bound and is out of scope; chat writes remain immediate.
- The user's current database is never mutated by tests; all tests use temporary database files.

## Testing

Focused tests cover:

- policy thresholds and compaction eligibility;
- chat archive encode/compress/decompress round trips, Unicode, metadata, and checksum rejection;
- archive transaction idempotency, overlapping-range rejection, read-back verification of the stored BLOB/metadata, affected-row mismatch rollback, and exact hot-row retention per conversation;
- removal of the legacy global 100-turn startup prune, including interleaved multi-session IDs;
- rollup backfill with fixed cutoffs/ID watermark, single-snapshot migration-time hybrid queries, exact-range deletion, expired-rollup cleanup, batch-marker cleanup, migration-complete watermark, and no double counting;
- immutable `active`/`inFlight` behavior when events arrive during a suspended flush, concurrent flush coalescing, UUID+digest acknowledgement matching, commit-success/acknowledgement-loss retry, and same-UUID/different-digest rejection;
- high-frequency sampling and buffered flush behavior with injected monotonic and wall clocks, including wall-clock rollback and sustained database failure proving each component cap, the 2,163-bucket/25,923-window process-wide cap, and expiry metrics;
- source-level exclusion proving the VitaPet directory root, database, WAL, SHM, vacuum-temp, adjacent prefix names such as `VitaPetBackup`, symlink aliases, and deleted paths are classified by path components correctly;
- a high-rate callback batch proving no per-item tasks are created, accepted counts survive representative-queue coalescing, the 4,096-entry detail cap and overflow/rescan event work, dropped/must-scan flags are surfaced, and source stop waits for its sole delivery worker;
- orderly termination proving source callback quiescence, bus seal/watermark drain, final `inFlight` then `active` commits, background-owner cancellation, persistence-write watermark drain, checkpoint/close, and exactly one termination reply occur in order, including retryable/nonretryable close results, pointer retention in `closeFailed`, late-write rejection, attempted reopen, lock-release ordering, repeated Quit requests, and watchdog expiry;
- raw-event retention by source;
- maintenance serialization, independent gate combinations, manual-action gate enforcement, and skip reasons;
- database statistics before and after deletion;
- a temporary large database proving full compaction and capped incremental reclamation reduce physical database-plus-WAL size and record post-checkpoint metrics;
- existing mood/behavior/interaction statistics returning the same logical totals, plus documented whole-hour semantics for rolled-up file-change trends.

The main verification remains a full SwiftPM build plus standalone assertion harnesses in environments where the installed command-line toolchain lacks XCTest.

## Rollout

0. Remove the legacy global `deleteOldTurns(keepLast: 100)` call and the unbounded generic startup `pruneOldEvents` call. Verify per-session chat history with interleaved IDs and prove a migration failure retains every unaccounted `fileChanged` row.
1. Exclude VitaPet's own Application Support tree at the filesystem event source, then ship additive core schema, ordered legacy-writer cutover/high-watermark capture, storage-degraded fallback, and read-only storage metrics.
2. Enable buffered ingestion and stable-batch hourly rollups for new `fileChanged` events; keep migration-time count queries in hybrid rollup-plus-unaccounted mode.
3. Set `retentionEnabled` only after archive read-back, exact-deletion, rollup-backfill, and crash-retry tests pass; conversation delete/clear already remove archives atomically before this gate opens.
4. Offer manual maintenance with `fullCompactionEnabled = false` and observe checkpoint, size, capacity, busy, and cancellation results.
5. Enable `fullCompactionEnabled` independently after those observations; this does not turn on scheduling.
6. Enable `schedulerEnabled` last, retaining independent kill switches for retention and compaction.

This ordering stops future runaway growth before performing any large rewrite. Chat deletion is protected by verified archives and retained file-change totals by reproducible rollups; rows beyond the explicit retention policy are intentionally and irreversibly expired.

## Non-Goals

- Cloud sync for chat archives.
- Full-text search inside compressed archives.
- Loading the entire historical archive into the live chat list.
- Retaining every historical file path after its 24-hour detailed window.
- Replacing SQLite or the existing persistence actor.
