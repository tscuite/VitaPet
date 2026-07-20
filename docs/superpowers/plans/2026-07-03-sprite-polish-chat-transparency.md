# Sprite Polish And Chat Transparency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve built-in sprite action richness and add a user-facing chat window transparency setting.

**Architecture:** Keep sprite generation deterministic by extending `scripts/generate_action_sprites.swift`, then regenerate all built-in pack PNGs and update manifests through the existing generation pipeline. Store chat appearance in `ConfigManager.AppConfig`, pass it through `AppDelegate` to `ChatWindowController`, and expose it in `SettingsView`.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWindow`, SwiftPM resources, deterministic PNG generation with `NSImage`.

---

### Task 1: Chat Transparency Configuration

**Files:**
- Modify: `Modules/Persistence/Sources/ConfigManager.swift`
- Modify: `Modules/Persistence/Tests/ConfigManagerTests.swift`

- [ ] **Step 1: Add failing decode/default tests**

Add tests asserting new config defaults:

```swift
XCTAssertFalse(config.chatWindowTranslucencyEnabled)
XCTAssertEqual(config.chatWindowOpacity, 1.0)
```

Add a decode compatibility test with JSON missing both fields and assert the same defaults.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigManagerTests`
Expected in this environment: `no such module 'XCTest'`; use a temporary non-XCTest Swift check if needed.

- [ ] **Step 3: Add config fields**

Add `chatWindowTranslucencyEnabled: Bool` and `chatWindowOpacity: Double` to `AppConfig`, initialize with defaults, decode with backwards-compatible defaults, include in `CodingKeys`, and clamp opacity to `0.55...1.0`.

- [ ] **Step 4: Verify config check passes**

Run a non-XCTest Swift check that decodes old JSON and constructs default config, asserting both fields.

### Task 2: Settings UI And Window Application

**Files:**
- Modify: `Modules/ChatUI/Sources/SettingsView.swift`
- Modify: `Modules/ChatUI/Sources/ChatWindowController.swift`
- Modify: `App/Sources/AppDelegate.swift`
- Modify: `Modules/ChatUI/Tests/*` if practical

- [ ] **Step 1: Add settings inputs**

Add `chatWindowTranslucencyEnabled`, `chatWindowOpacity`, and `onSaveChatAppearance` to `SettingsView` and `ChatWindowController.showSettings()`.

- [ ] **Step 2: Add a settings section**

Add a concise "聊天窗口" section with:

```swift
Toggle("半透明", isOn: $chatWindowTranslucencyEnabled)
Slider(value: $chatWindowOpacity, in: 0.55...1.0, step: 0.05)
```

Persist changes via `onSaveChatAppearance(enabled, opacity)`.

- [ ] **Step 3: Apply window appearance**

In `ChatWindowController`, apply:

```swift
window.isOpaque = !enabled
window.backgroundColor = enabled ? .clear : .windowBackgroundColor
window.alphaValue = enabled ? CGFloat(opacity) : 1
```

Apply before showing chat and settings.

- [ ] **Step 4: Wire persistence**

In `AppDelegate`, pass config values into `ChatWindowController` and update config in the save closure.

- [ ] **Step 5: Verify build**

Run: `swift build --product VitaPetApp`
Expected: build completes.

### Task 3: Sprite Frames And Longer Action Timing

**Files:**
- Modify: `scripts/generate_action_sprites.swift`
- Modify: `Modules/RenderEngine/Sources/ActionComboPlanner.swift`
- Modify: `Modules/RenderEngine/Sources/SpritePackManager.swift`
- Modify/generated: built-in sprite PNGs and manifests under `Modules/RenderEngine/Resources*`
- Modify tests under `Modules/RenderEngine/Tests` if practical

- [ ] **Step 1: Extend frame counts**

Change deterministic generated actions from mostly 1-2 frames to 3-5 frames for expressive states.

- [ ] **Step 2: Improve generated details**

Add more expressive overlays: face changes, motion streaks, sparkle density, music notes, paw emphasis, tail arcs, soft ground shadows.

- [ ] **Step 3: Regenerate assets**

Run: `swift scripts/generate_action_sprites.swift`
Expected: generated PNG count increases for all four built-in packs.

- [ ] **Step 4: Update manifests**

Use the existing manifest generation/update path if present, otherwise update frame arrays for generated actions so every generated PNG is referenced.

- [ ] **Step 5: Lengthen action timing**

Increase action frame intervals and combo segment durations for richer motions without making ordinary idle behavior sluggish.

- [ ] **Step 6: Verify resources and build**

Run: `swift build --target RenderEngine`
Run: `swift build --product VitaPetApp`
Expected: both builds complete.

### Task 4: Install And Restart

**Files:**
- No code files.

- [ ] **Step 1: Build installer bundle**

Run: `./scripts/build_app.sh`
Expected: `/Applications/VitaPet.app` is updated and restarted.

- [ ] **Step 2: Confirm process**

Run: `pgrep -af VitaPetApp`
Expected: a running PID is printed.
