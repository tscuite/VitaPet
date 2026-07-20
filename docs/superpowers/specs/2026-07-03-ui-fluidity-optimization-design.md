# VitaPet UI Fluidity Optimization Design

## Goal

Improve perceived smoothness across the desktop pet, animation behavior, chat window, and settings/menu surfaces without rewriting the app architecture or changing persisted data formats.

## Selected Approach

Use a conservative global pass:

- Reduce high-frequency main-thread window work by coalescing drag/movement updates and sharing frame interpolation logic.
- Reduce SwiftUI invalidation during AI streaming by flushing text and auto-scroll less aggressively.
- Lightly simplify visual styling where expensive gradients, shadows, and material layers are used in compact controls.
- Keep existing public behavior, settings, sprite packs, plugin APIs, and database schemas unchanged.

## Alternatives Considered

1. Full UI rewrite around a new design system.
   This would produce a cleaner long-term surface but has too much blast radius for a general optimization request.

2. Performance-only pass with no visual changes.
   This is safer but would miss the user's request to adjust the interface and improve overall feel.

3. Conservative global pass.
   This gives the best near-term result: smoother hot paths, restrained visual cleanup, and low risk to existing features.

## Scope

In scope:

- Desktop pet drag and programmatic movement smoothness.
- Behavior and animation scheduling paths used by idle movement, jumps, chase, follow, and desktop awareness.
- Chat streaming update cadence, scrolling cadence, and message bubble rendering cost.
- Compact visual polish for chat surfaces and settings/menu controls.
- Focused tests for newly extracted pure behavior.

Out of scope:

- Replacing SpriteKit or SwiftUI.
- Reworking the persistence layer.
- Changing AI provider behavior or plugin contracts.
- Major settings page restructuring.

## Architecture

Introduce small, testable helpers where the current implementation repeats interpolation or throttling logic. AppKit window movement remains in `PetWindowController`, but progress calculation becomes pure and test-covered. Chat streaming remains in `ChatViewModel`, but flush cadence becomes clearer and less aggressive. SwiftUI view polish stays local to `ChatUI` files.

## Components

- `RenderEngine` movement helper: pure interpolation and frame-count calculation for smooth window motion.
- `PetWindowController`: use the movement helper for debug movement, behavior movement, and somersault movement; reduce redundant nested `Task` hops where the timer is already on the main run loop.
- `ChatViewModel`: increase streaming batching interval and avoid needless preview updates until the final assistant content.
- `ChatView`: reduce streaming scroll frequency and use non-localized dynamic text rendering in message bubbles.
- `.gitignore`: ignore `.superpowers/` visual brainstorming cache.

## Error Handling

Existing behavior cancellation remains authoritative. Movement timers must still invalidate on completion and cancellation. If a target duration is zero or negative, movement should snap to the target exactly as it does today.

## Testing

- Add focused `RenderEngine` tests for movement progress and frame-count behavior.
- Add focused `ChatUI` tests if a pure streaming helper is introduced.
- Use `swift build` as the main verification command in this environment because `swift test` currently fails before running tests due missing `XCTest` in the active command line toolchain.

## Approval

The user approved broad optimization and asked not to pause for further confirmation. This design proceeds with conservative implementation decisions.
