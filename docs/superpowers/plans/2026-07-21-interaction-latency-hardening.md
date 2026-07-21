# Interaction Latency Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use test-driven-development for every behavior change and request independent review before final integration.

**Goal:** Make page switching, streaming, dragging, and mini-games predictably responsive while reducing startup and persistence contention.

**Architecture:** Reuse two typed AppKit/SwiftUI surfaces, guard expensive representable updates, isolate streaming drafts from settled history, make movement ownership synchronous and cancellable, and apply explicit startup/event policies.

**Tech Stack:** Swift 6, SwiftUI, AppKit, SpriteKit, SwiftPM, standalone Swift harnesses, Instruments/sample/top.

---

## Task 1: Persistent Chat and Settings Surfaces

**Files:**
- Create `Modules/ChatUI/Sources/ReusableHostingSurface.swift`
- Create `Modules/ChatUI/Tests/ReusableHostingSurfaceTests.swift`
- Modify `Modules/ChatUI/Sources/ChatWindowController.swift`
- Modify `.tmp/ui-switch-benchmark/*` only for ignored measurement support

- Write a failing cache harness proving repeated resolution currently has no reusable typed host abstraction.
- Implement a reusable typed surface that creates once and refreshes content on later resolutions.
- Replace the discarded startup host with a plain placeholder.
- Lazily reuse exactly the chat and settings hosts; skip `window.contentView` assignment when already active.
- Re-run the release benchmark and record cold/warm/switch results.

## Task 2: Settings Preview and Chat Streaming Hot Paths

**Files:**
- Modify `Modules/ChatUI/Sources/SpritePackPreviewView.swift`
- Modify `Modules/ChatUI/Sources/ChatViewModel.swift`
- Modify `Modules/ChatUI/Sources/ChatView.swift`
- Modify `Modules/ChatUI/Sources/MessageBubble.swift`
- Add focused tests under `Modules/ChatUI/Tests`

- Write failing tests/harnesses for preview configuration equality, streaming draft replacement independent of settled history length, single parsing per render policy, and near-bottom auto-scroll policy.
- Skip sprite scene recreation when pack path and preview size are unchanged.
- Keep intermediate assistant content in a dedicated draft/presentation path and commit it once at completion/cancellation; preserve conversation routing and persistence callback semantics.
- Parse message content once per body evaluation.
- Track the bottom sentinel and follow streaming only while near bottom; resume when the user returns to the bottom.
- Run all standalone chat regressions plus a strict ChatUI build.

## Task 3: Single-Writer Pet Movement and Mini-Game Cadence

**Files:**
- Modify `Modules/RenderEngine/Sources/BehaviorEngine.swift`
- Modify `Modules/RenderEngine/Sources/PetScene.swift`
- Modify `App/Sources/PetWindowController.swift`
- Modify `App/Sources/Games/HideAndSeekGame.swift`
- Modify other game timer files only where the same Timer-to-MainActor hop is proven
- Add focused RenderEngine tests/harnesses

- Write failing ownership/idempotence tests before production changes.
- Cancel controller movement and behavior on drag and game ownership entry.
- Make BehaviorEngine callbacks main-actor synchronous and remove controller task hops; make ordinary move completion share the interpolation clock or otherwise guarantee the final target frame precedes completion.
- Make same-state transition and same-facing updates no-ops.
- Exclude found pets from the hiding pass, transition each found pet to follow once, and perform no more than one position write per pet per tick.
- Use elapsed-time movement and main-run-loop common mode where timer cadence is touched.
- Run RenderEngine regressions and strict full build.

## Task 4: High-Frequency Event and Startup Contention

**Files:**
- Create an explicit event persistence policy in `App/Sources` or `Modules/Persistence/Sources`
- Modify `App/Sources/AppDelegate.swift`
- Add focused tests/harnesses

- Write failing policy tests showing raw key-down telemetry should not be persisted.
- Keep `hotkeyPressed` delivery to EventBus/plugins but skip its SQLite history write.
- Write a startup-order test seam proving remote memory work starts after local UI readiness.
- Track deferred remote-memory bootstrap work, cancel/join it in orderly shutdown, and retain periodic retry behavior.
- Load local memory context before or independently from remote work without delaying visible pet/status UI.

## Task 5: Cross-Module Verification and Delivery

**Files:**
- Review all files changed above
- Update documentation only if verified behavior differs from the plan

- Run red/green standalone harnesses and existing regression harnesses relevant to chat, render, persistence, cancellation, and shutdown.
- Run strict debug and release builds with the host-compatible target triple.
- Re-run UI switching benchmark and runtime idle/interaction samples.
- Run `git diff --check`, inspect the full diff, and scan tracked changes for credentials/private paths.
- Use the local release/install script, verify code signature and running process, then commit and push the reviewed changes.
