# AI Model Selection Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Prevent VitaPet from silently replacing a non-empty configured AI model when the backend changes.

**Architecture:** Put the model normalization policy in a pure AIEngine API and route settings, app configuration, and request construction through it. Blank input uses the backend default; every explicit value is preserved.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager, XCTest plus a standalone Swift harness for environments where XCTest is unavailable.

---

### Task 1: Lock the model-selection contract with tests

**Files:**
- Create: `Modules/AIEngine/Tests/AIModelSelectionTests.swift`
- Create temporarily: `.tmp/AIModelSelectionHarness.swift`

- [x] **Step 1: Write the failing regression test**

```swift
func testExplicitPreviousDefaultIsPreservedAcrossBackendChange() {
    XCTAssertEqual(
        AIModelSelection.resolvedModel("llama3.2", for: .openAICompatible),
        "llama3.2"
    )
}
```

- [x] **Step 2: Run the harness and verify RED**

Run: `swiftc Modules/AIEngine/Sources/AIEngine.swift .tmp/AIModelSelectionHarness.swift -o .tmp/ai-model-selection-harness`

Expected: compilation fails because `AIModelSelection` does not exist.

### Task 2: Centralize model resolution

**Files:**
- Modify: `Modules/AIEngine/Sources/AIEngine.swift`
- Modify: `Modules/AIEngine/Sources/OllamaService.swift`

- [x] **Step 1: Add the minimal pure implementation**

```swift
public enum AIModelSelection {
    public static func resolvedModel(_ rawValue: String, for backend: AIBackend) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? backend.defaultModel : trimmed
    }
}
```

- [x] **Step 2: Make request resolution call the shared policy**

Replace the private duplicate trimming/default logic in `OllamaService` with `AIModelSelection.resolvedModel(model, for: backend)`.

- [x] **Step 3: Run the harness and verify GREEN**

Run the same `swiftc` command and execute `.tmp/ai-model-selection-harness`.

Expected: `ai model selection harness: PASS`.

### Task 3: Remove backend-switch model substitution

**Files:**
- Modify: `Modules/ChatUI/Sources/SettingsView.swift`
- Modify: `App/Sources/AppDelegate.swift`

- [x] **Step 1: Preserve the current non-empty model in Settings**

```swift
.onChange(of: aiBackend) { _, newValue in
    ollamaModel = AIModelSelection.resolvedModel(ollamaModel, for: newValue)
    scheduleAIConfigSave(immediate: true)
}
```

- [x] **Step 2: Use the same policy during startup and save**

Replace `normalizedAIModel` and its `previousBackend` rewrite with `AIModelSelection.resolvedModel`.

- [x] **Step 3: Build and run focused regression checks**

Run the standalone harness and build `VitaPetApp` with the repository's SDK overlay command.

Expected: harness passes and the product builds without errors.

### Task 4: Review, verify, and release

**Files:**
- Modify only files required by concrete high-severity review findings.

- [x] **Step 1: Review recent AI, storage, UI, and rendering changes**

Record only reproducible correctness or safety issues; avoid unrelated refactors.

- [x] **Step 2: Add a failing test before each additional fix**

Use the relevant package test or a standalone deterministic harness when XCTest cannot be loaded by the installed Command Line Tools.

- [x] **Step 3: Run final verification**

Run build, focused harnesses, `git diff --check`, and a sensitive-information scan.

- [x] **Step 4: Commit and push**

```bash
git add Modules/AIEngine/Sources/AIEngine.swift \
  Modules/AIEngine/Sources/OllamaService.swift \
  Modules/AIEngine/Tests/AIModelSelectionTests.swift \
  Modules/ChatUI/Sources/SettingsView.swift \
  App/Sources/AppDelegate.swift \
  docs/superpowers/specs/2026-07-20-ai-model-selection-stability-design.md \
  docs/superpowers/plans/2026-07-20-ai-model-selection-stability.md
git commit -m "fix: preserve explicit AI model selection"
git push origin main
```
