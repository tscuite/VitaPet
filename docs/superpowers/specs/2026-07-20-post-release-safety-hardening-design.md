# Post-release Safety Hardening Design

## Scope

This hardening pass addresses reproducible correctness defects found after the storage-lifecycle release. It does not redesign unrelated UI or rendering code.

## Storage correctness

Maintenance captures one fixed `now`, detail cutoff, retention cutoff, and maximum event ID before changing rows. Legacy `fileChanged` rows are selected in deterministic ID order with `unixepoch(timestamp)`, grouped into UTC-hour buckets, and deleted by their exact IDs in the same transaction. Accounted samples older than 24 hours are detail-only and may be deleted. Other event sources retain 30 days. Hourly buckets expire only when the complete bucket ends before the retention cutoff.

Statistics use one SQL statement per query. `fileChanged` totals equal committed rollups plus unaccounted raw legacy rows; accounted representative rows are excluded so they cannot double-count. Other sources remain raw-authoritative. Daily totals apply the same rule.

Initialization records a stable legacy high watermark in `storage_metadata` before buffered ingestion starts. Maintenance never aggregates or deletes an unaccounted `fileChanged` row above that watermark. The migration-complete marker is written only after no eligible legacy rows remain.

## Maintenance and space reporting

Maintenance deletes acknowledged batch markers older than seven days, checkpoints the WAL with truncate mode, and performs bounded incremental vacuum only when the database is already in incremental auto-vacuum mode. Storage summaries use aggregate SQL and never load archive BLOBs merely to count them.

Automatic and manual callers share one maintenance coordinator task. Existing databases must create and verify the optimized events index before automatic maintenance is enabled.

## Ordered shutdown

Event delivery becomes awaitable: `EventBus.publish` waits for subscribed handlers. Callback-based sources track outstanding publications and drain them after intake stops. `recordEvent` awaits recorder admission instead of creating another detached task.

Shutdown stops and drains event sources first, unsubscribes the handler, seals the recorder, seals the persistence write gate and waits through its watermark, then flushes the recorder, checkpoints/closes the database, releases the single-instance lock, and replies exactly once. `DatabaseManager` enters a terminal closed state so late work cannot reopen SQLite.

## AI configuration reliability

The explicit backend is authoritative. Endpoint text is never allowed to override an existing picker selection; only legacy configuration that lacks `aiBackend` is inferred once while decoding. Configuration updates publish the new in-memory value only after the atomic file write succeeds. A failed save does not update the running service. Closing settings flushes a dirty AI draft rather than cancelling it.

## Verification

All database tests use temporary files. Regression coverage includes timestamp conversion, maintenance count conservation, hybrid counts, ordinary retention, marker cleanup, aggregate metrics, write-gate drainage, terminal database close, backend preservation, failed-save rollback, and settings draft flush. Standalone harnesses provide executable coverage when the installed Command Line Tools cannot import XCTest.
