import AppKit
import ChatUI
import Combine
import Localization
import SwiftUI
import UsageMonitor

@MainActor
final class UsageBarController: NSObject, NSWindowDelegate {
    let store: UsageMonitorStore
    private var panel: UsageBarPanel?
    private var hostingView: UsageBarHostingView?
    private var settingsWindow: NSWindow?
    private var observations = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var started = false

    var isVisible: Bool { store.settings.isVisible }

    init(store: UsageMonitorStore = UsageMonitorStore()) {
        self.store = store
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        store.$settings.removeDuplicates()
            // @Published emits before the store changes; lay out on the next main turn.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePanel() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePanel() }
            .store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePanel() }
            .store(in: &observations)
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerRouting() }
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointerRouting() }
            return event
        }) { mouseMonitors.append(monitor) }
        updatePanel()
        // The store gates all credential access and requests on explicit monitoring opt-in.
        store.start()
    }

    func stop() async {
        started = false
        observations.removeAll()
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        panel?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        settingsWindow?.contentView = nil
        await store.stop()
    }

    func toggleVisibility() {
        guard started else { return }
        store.updateSettings { $0.isVisible.toggle() }
    }

    func resetPosition() {
        store.updateSettings {
            $0.edge = .top
            $0.horizontalPosition = 0.5
            $0.screenID = nil
        }
    }

    func showSettings() {
        guard started else { return }
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = L10n.tr("usage.settings.window_title")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 480)
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        if settingsWindow?.contentView == nil {
            settingsWindow?.contentView = NSHostingView(rootView: UsageBarSettingsView(
                store: store, onResetPosition: { [weak self] in self?.resetPosition() }
            ))
        }
        // Activation is reserved for this explicit user action, never strip startup.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        // A closed Form must not keep observing quota updates and laying out offscreen.
        window.contentView = nil
    }

    private func stripRoot(fit: CGFloat = 1, size: NSSize? = nil) -> AnyView {
        AnyView(UsageBarView(store: store, onOpenSettings: { [weak self] in self?.showSettings() })
            .fixedSize()
            .scaleEffect(fit)
            .frame(width: size?.width, height: size?.height))
    }

    private func updatePanel() {
        guard started else { return }
        guard store.settings.isVisible else {
            panel?.orderOut(nil)
            return
        }
        let selectedScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
                == store.settings.screenID
        }
        guard let screen = selectedScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let panel = UsageBarPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            // CodeNotch's panel sits at the physical bezel, above the menu bar.
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // Keep pointer events available to provider buttons and detail popovers.
            panel.isMovableByWindowBackground = false
            let host = UsageBarHostingView(rootView: stripRoot())
            panel.contentView = host
            self.panel = panel
            hostingView = host
        }
        guard let panel, let hostingView else { return }
        panel.appearance = store.settings.surfaceStyle.panelAppearance(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        hostingView.rootView = stripRoot()
        let naturalSize = hostingView.fittingSize
        let frame = Self.frame(
            contentSize: naturalSize, screenFrame: screen.frame,
            edge: store.settings.edge, horizontalPosition: store.settings.horizontalPosition
        )
        let fit = min(1, frame.width / max(1, naturalSize.width), frame.height / max(1, naturalSize.height))
        hostingView.rootView = stripRoot(fit: fit, size: frame.size)
        let settings = store.settings
        hostingView.containsChrome = { point in
            UsageBarView.containsInteraction(at: CGPoint(x: point.x / fit, y: point.y / fit), settings: settings)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        updatePointerRouting()
    }

    /// Like CodeNotch, a global monitor wakes the panel from click-through, and a
    /// local monitor releases it again. Mouse-only monitoring needs no AX prompt.
    func updatePointerRouting(at location: NSPoint = NSEvent.mouseLocation) {
        guard started, let panel, panel.isVisible, let hostingView else { return }
        let point = CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
        let ignores = !hostingView.containsChrome(point)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    /// Horizontal position is a fraction of available travel, not absolute screen coordinates.
    static func frame(contentSize: NSSize, screenFrame: NSRect, edge: UsageBarEdge, horizontalPosition: Double) -> NSRect {
        let naturalWidth = contentSize.width.isFinite ? max(1, contentSize.width) : 1
        let naturalHeight = contentSize.height.isFinite ? max(1, contentSize.height) : 1
        let fit = min(1, max(1, screenFrame.width) / naturalWidth, max(1, screenFrame.height) / naturalHeight)
        let width = naturalWidth * fit
        let height = naturalHeight * fit
        let position = horizontalPosition.isFinite ? min(1, max(0, horizontalPosition)) : 0.5
        return NSRect(
            x: screenFrame.minX + (screenFrame.width - width) * position,
            y: edge == .top ? screenFrame.maxY - height : screenFrame.minY,
            width: width, height: height
        )
    }
}

@MainActor
private final class UsageBarHostingView: NSHostingView<AnyView> {
    var containsChrome: (CGPoint) -> Bool = { _ in false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsChrome(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
private final class UsageBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
