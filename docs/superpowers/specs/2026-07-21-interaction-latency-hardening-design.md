# VitaPet Interaction Latency Hardening Design

## Goal

Remove the repeatable main-thread stalls and competing animation writers that make VitaPet feel uneven during page switching, AI streaming, pet dragging, and mini-games. Keep persistence formats, plugin event delivery, AI behavior, and visible product features compatible.

## Evidence

The work is driven by measured and code-level evidence rather than broad visual rewrites:

- Release benchmark before changes: cold chat 395.41 ms, cold settings 194.65 ms, warm chat median 51.69 ms, and an eight-cycle chat/settings switch average of 134.89 ms.
- A five-second idle sample showed the main thread blocked in the AppKit event loop and CPU near zero, so the issue is interaction-time work rather than an idle loop.
- `ChatWindowController` creates and attaches a new `NSHostingView` on every chat/settings presentation. The controller also creates a startup `ChatView` host that is discarded before the real tabbed chat is shown.
- Settings sprite previews rebuild a `PetScene`, decode a manifest, and load textures from every `updateNSView`, including unrelated SwiftUI invalidations.
- Chat streaming repeatedly searches and copies the full message array on the main actor; message bubbles parse the growing response twice per body evaluation; streaming always forces the user back to the bottom.
- Dragging, behavior timers, combo movement, and mini-games can write the same pet window in one frame. Hide-and-seek additionally transitions already-found pets to the same state at 60 Hz.
- Every key-down event is still delivered to plugins as intended, but the AppDelegate also creates a persistence write for it. This adds task and SQLite pressure while the user is typing.
- With remote memory enabled, startup awaits a remote pull and as many as 200 serial uploads before creating visible pet windows.

## Selected Approach

Use bounded, state-preserving optimizations at the existing architectural seams:

1. Keep one lazily-created hosting surface for chat and one for settings. Refresh the typed SwiftUI root value before reuse so current providers are sampled, but do not recreate or reattach the AppKit hosting bridge when the requested surface is already active. Start the controller with a plain placeholder view.
2. Make sprite preview rendering configuration-aware. A coordinator records the rendered pack path and size and skips scene reconstruction for unrelated updates.
3. Separate live streaming presentation from settled conversation history, or otherwise guarantee that intermediate snapshots do not copy the full history. Parse each message body once per render. Auto-scroll only while the bottom sentinel is near the viewport; once the user scrolls upward, streaming must not steal position.
4. Enforce one movement owner. Starting a drag or mini-game cancels behavior and controller movement first. Behavior frame callbacks execute synchronously on the main actor instead of queuing unowned tasks. State/facing transitions are idempotent, and hide-and-seek excludes found pets from the hiding pass and transitions them to follow once.
5. Classify raw keyboard input as transient telemetry: it remains on EventBus for shortcuts and plugins but is not inserted into SQLite. The policy is explicit and testable rather than a switch hidden inside database code.
6. Move remote-memory bootstrap synchronization behind visible UI startup and track the task in orderly shutdown. Local memory context is loaded promptly; remote pull/upload remains best-effort and periodic synchronization remains unchanged.

## Compatibility and Safety

- At most two heavy SwiftUI surfaces are retained, so reuse is bounded rather than an unbounded page cache.
- Reassigning a cached host's root keeps provider values fresh. Existing view-local state remains owned by SwiftUI where identity is stable.
- Activity, statistics, and sprite-pack creator pages remain uncached because they are lower-frequency and some are intentionally transient.
- Keyboard events continue to reach EventBus subscribers. Only historical persistence of raw keystrokes is removed, which also reduces unnecessary sensitive telemetry.
- Cancellation tokens remain authoritative. No timer may mutate a pet window after a drag/game has claimed movement ownership.
- Remote startup sync must honor termination, be joined during shutdown, and must not delay initial pet/status UI.

## Testing Strategy

The active Command Line Tools installation cannot run XCTest at the deployment target because its compiler/SDK and XCTest modules are inconsistent. Every new pure policy/helper therefore gets both checked-in XCTest coverage and a standalone ignored harness used for the required red/green cycle. Full SwiftPM builds use the host-compatible macOS 26 triple; the normal release script remains the packaging authority.

Performance acceptance checks:

- The same release chat/settings benchmark must reduce repeated switch average by at least 50% from 134.89 ms and must construct each heavy hosting surface once.
- Repeated `SpritePackPreviewView.updateNSView` calls with the same configuration must not rebuild a scene.
- Streaming snapshot work must not scale with settled message count on its hot path, and user-upward scroll must disable follow-to-bottom until the sentinel returns near bottom.
- Drag/game entry must invalidate prior movement ownership; hide-and-seek must perform at most one position write per pet per tick and no repeated follow transition.
- `hotkeyPressed` must be rejected by persistence policy while shortcut/plugin delivery remains unchanged.
- Startup sequencing tests must show visible UI setup preceding remote memory pull/upload.

## Approval

The user explicitly requested autonomous, substantial optimization, asked not to be questioned again, and authorized completion, local installation, commit, and push. This design proceeds without another approval checkpoint.
