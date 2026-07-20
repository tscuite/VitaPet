# UI Fluidity Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve VitaPet's desktop pet movement, chat streaming, and compact UI polish while preserving existing behavior.

**Architecture:** Extract pure movement timing math into `RenderEngine` so AppKit movement paths share tested interpolation. Keep high-level behavior in existing controllers and make SwiftUI updates less aggressive during streaming.

**Tech Stack:** Swift 6, SwiftPM, AppKit, SwiftUI, SpriteKit, XCTest where available.

---

## File Structure

- Modify `.gitignore`: ignore `.superpowers/` generated visual companion cache.
- Create `Modules/RenderEngine/Sources/MotionFramePlanner.swift`: pure frame and interpolation helper.
- Create `Modules/RenderEngine/Tests/MotionFramePlannerTests.swift`: tests for the helper.
- Modify `App/Sources/PetWindowController.swift`: use the helper for timed movement paths and avoid extra main-actor task hops inside main-run-loop timers.
- Modify `Modules/ChatUI/Sources/ChatViewModel.swift`: tune streaming flush cadence and keep preview updates deferred.
- Modify `Modules/ChatUI/Sources/ChatView.swift`: tune streaming auto-scroll cadence.
- Modify `Modules/ChatUI/Sources/MessageBubble.swift`: render dynamic AI text directly instead of through `LocalizedStringKey`.

## Tasks

### Task 1: Movement Planning Helper

**Files:**
- Create: `Modules/RenderEngine/Sources/MotionFramePlanner.swift`
- Create: `Modules/RenderEngine/Tests/MotionFramePlannerTests.swift`

- [ ] Write tests for frame count, interpolation midpoint, and clamped completion.
- [ ] Verify the tests fail because `MotionFramePlanner` does not exist.
- [ ] Implement `MotionFramePlanner` with `steps(forDuration:frameRate:)` and `point(from:to:step:steps:)`.
- [ ] Verify the new tests pass when the local toolchain supports XCTest.

### Task 2: Pet Window Movement Paths

**Files:**
- Modify: `App/Sources/PetWindowController.swift`

- [ ] Replace repeated `duration * fps` and linear interpolation code with `MotionFramePlanner`.
- [ ] Keep timer invalidation, `movementTimer = nil`, bubble repositioning, and position persistence behavior unchanged.
- [ ] Remove nested `Task { @MainActor }` wrappers from timers that are already scheduled on the main run loop.
- [ ] Build with `swift build`.

### Task 3: Chat Streaming Cadence

**Files:**
- Modify: `Modules/ChatUI/Sources/ChatViewModel.swift`
- Modify: `Modules/ChatUI/Sources/ChatView.swift`
- Modify: `Modules/ChatUI/Sources/MessageBubble.swift`

- [ ] Increase model streaming UI flush interval from 40 ms to a smoother, lower-churn interval.
- [ ] Increase streaming scroll throttle from 80 ms to a lower-churn interval.
- [ ] Render dynamic message text as plain `Text` instead of `Text(LocalizedStringKey(...))`.
- [ ] Build with `swift build`.

### Task 4: Visual Polish

**Files:**
- Modify: `Modules/ChatUI/Sources/ChatView.swift`
- Modify: `Modules/ChatUI/Sources/TabbedChatView.swift`

- [ ] Simplify compact chat control backgrounds and reduce heavy shadows/material layering where it adds redraw cost.
- [ ] Keep dimensions stable so controls do not shift during streaming.
- [ ] Build with `swift build`.

### Task 5: Final Verification

**Files:**
- No new files beyond prior tasks.

- [ ] Run `swift build`.
- [ ] Run `swift test --list-tests` or `swift test list` to document whether the active toolchain can discover tests.
- [ ] Review `git diff` for accidental unrelated changes.
