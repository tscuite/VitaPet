# Post-release Safety Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Eliminate silent model/config regressions, storage-count loss, and accepted-write loss during shutdown.

**Architecture:** Keep model/config policies pure and atomic, make rollups authoritative through hybrid SQL, and add explicit drainage barriers around asynchronous event and persistence work. Destructive maintenance remains bounded by fixed cutoffs and a persisted migration watermark.

**Tech Stack:** Swift 6 actors, SwiftUI, SQLite3, Swift Package Manager, XCTest, standalone temporary-database harnesses.

---

### Task 1: Make AI configuration explicit and atomic

**Files:**
- Modify: `Modules/Persistence/Sources/ConfigManager.swift`
- Modify: `Modules/Persistence/Tests/ConfigManagerTests.swift`
- Modify: `Modules/ChatUI/Sources/SettingsView.swift`
- Modify: `App/Sources/AppDelegate.swift`

- [x] Add RED tests proving a failed config write leaves `config` unchanged and a legacy config without `aiBackend` infers it from the endpoint.
- [x] Encode and atomically write a candidate configuration before assigning it to `config`.
- [x] Remove runtime endpoint-based backend overrides; preserve the explicit backend.
- [x] Track dirty AI settings and synchronously flush the final draft on disappear and before connection testing.
- [x] Return immediately when persistence fails so the service cannot diverge from disk.

### Task 2: Conserve event counts through bounded maintenance

**Files:**
- Create: `Modules/Persistence/Tests/StorageMaintenanceTests.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager+StorageSchema.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager+StorageMaintenance.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager.swift`

- [x] Add RED temporary-database tests for correct UTC buckets, count conservation, exact-ID/watermark behavior, hybrid source and daily totals, 30-day ordinary retention, and seven-day marker cleanup.
- [x] Persist an idempotent legacy `fileChanged` high watermark during schema initialization.
- [x] Select `unixepoch(timestamp)` and reject invalid timestamps instead of mapping them to epoch zero.
- [x] Backfill and delete exact bounded ID sets; restrict 24-hour detail deletion to accounted `fileChanged` samples.
- [x] Replace raw-only statistics with single-statement hybrid queries.
- [x] Truncate-checkpoint and run bounded incremental vacuum when supported.

### Task 3: Add lightweight storage metrics and maintenance coalescing

**Files:**
- Modify: `Modules/Persistence/Sources/StorageModels.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager+StorageMaintenance.swift`
- Modify: `App/Sources/AppDelegate.swift`

- [x] Add aggregate metrics that use `COUNT`/`SUM(LENGTH(...))` without selecting archive payloads.
- [x] Route refresh UI through metrics rather than `listConversationArchives()`.
- [x] Coalesce concurrent automatic/manual maintenance calls into one task and require optimized index readiness before scheduling.

### Task 4: Drain accepted event and persistence work at shutdown

**Files:**
- Create: `Modules/EventBus/Sources/EventPublicationTracker.swift`
- Modify: `Modules/EventBus/Sources/EventBus.swift`
- Modify callback-based event sources under `Modules/EventBus/Sources/`
- Modify: `Modules/Persistence/Sources/PersistenceWriteGate.swift`
- Modify: `Modules/Persistence/Sources/DatabaseManager.swift`
- Modify: `App/Sources/AppDelegate.swift`

- [x] Add RED tests/harnesses showing publication and write-gate drainage wait for suspended work.
- [x] Make publish await all matching handlers and make callbacks use a tracked publication owner.
- [x] Add `sealAndWait()` to the write gate.
- [x] Make `recordEvent` async and remove its detached recorder task.
- [x] Seal/drain in source → recorder/write gate → database order.
- [x] Make database close terminal and reject calls after close.

### Task 5: Verify and release

**Files:**
- Modify only files implicated by failing regression checks or review findings above.

- [x] Run all focused standalone harnesses.
- [x] Build `VitaPetApp` with strict concurrency.
- [x] Run `git diff --check` and scan the diff for credentials.
- [x] Run the local update script and smoke-check the installed app.
- [x] Commit and push reviewed changes to `main`.
