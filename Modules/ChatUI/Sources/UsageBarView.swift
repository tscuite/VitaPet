import AppKit
import Localization
import SwiftUI
import UsageMonitor

@MainActor
public struct UsageBarView: View {
    @ObservedObject private var store: UsageMonitorStore
    private let onOpenSettings: () -> Void
    @Environment(\.usageReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    public init(store: UsageMonitorStore, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onOpenSettings = onOpenSettings
    }

    private var appearance: ColorScheme {
        store.settings.surfaceStyle.panelAppearance(reduceTransparency: reduceTransparency) == nil ? colorScheme : .dark
    }

    /// The same outline is used by the panel's native hit test and pointer routing.
    /// Transparent flare pockets must not block the menu bar or windows underneath.
    public static func containsInteraction(at point: CGPoint, settings: UsageBarSettings) -> Bool {
        let scale = settings.scale
        let width = UsageNotchLayout.shapeLength(count: max(1, settings.providers.count)) * scale
        let height = UsageNotchLayout.bodyDepth * scale
        // Global mouse events usually land outside the clipped strip; skip building its curves.
        guard CGRect(x: 0, y: 0, width: width + UsageNotchLayout.orbExtent * scale, height: height)
            .contains(point) else { return false }
        let bleed = settings.edge == .top ? -UsageNotchLayout.bezelBleed : UsageNotchLayout.bezelBleed
        let bodyPoint = CGPoint(x: point.x, y: point.y - bleed)
        if UsageNotchShape(edge: settings.edge, scale: scale)
            .path(in: CGRect(x: 0, y: 0, width: width, height: height)).contains(bodyPoint) { return true }
        let orbY = settings.edge == .top ? UsageNotchLayout.curlRadius * scale : height - UsageNotchLayout.curlRadius * scale
        return hypot(point.x - width, point.y - orbY) <= UsageNotchLayout.orbExtent * scale
    }

    public var body: some View {
        let scale = store.settings.scale
        let width = UsageNotchLayout.shapeLength(count: max(1, store.settings.providers.count)) * scale
        let height = UsageNotchLayout.bodyDepth * scale
        let shape = UsageNotchShape(edge: store.settings.edge, scale: scale)
        ZStack(alignment: .topLeading) {
            HStack(spacing: UsageNotchLayout.cellSpacing * scale) {
                if store.settings.providers.isEmpty {
                    Button(action: onOpenSettings) {
                        Label(L10n.tr("usage.empty"), systemImage: "plus.circle")
                            .font(.system(size: 12 * scale, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.tr("usage.settings"))
                } else {
                    ForEach(store.settings.providers) { provider in
                        UsageProviderCell(store: store, provider: provider, onOpenSettings: onOpenSettings)
                    }
                }
            }
            .frame(width: width, height: height)
            .background {
                UsageNotchSurface(style: store.settings.surfaceStyle)
                    .opacity(reduceTransparency ? 1 : store.settings.opacity)
            }
            .clipShape(shape)
            .contentShape(shape)
            .offset(y: store.settings.edge == .top ? -UsageNotchLayout.bezelBleed : UsageNotchLayout.bezelBleed)

            UsageSettingsOrb(edge: store.settings.edge, scale: scale,
                             surfaceStyle: store.settings.surfaceStyle, opacity: store.settings.opacity,
                             action: onOpenSettings)
                .position(x: width, y: store.settings.edge == .top
                    ? UsageNotchLayout.curlRadius * scale
                    : height - UsageNotchLayout.curlRadius * scale)
        }
        .frame(width: width + UsageNotchLayout.orbExtent * scale, height: height)
        .clipped()
        .foregroundStyle(.primary)
        .environment(\.colorScheme, appearance)
        .contextMenu {
            Button(L10n.tr("usage.refresh")) { store.refresh() }
                .disabled(!store.settings.monitoringEnabled || store.isRefreshing)
            Button(L10n.tr("usage.settings"), action: onOpenSettings)
            Divider()
            Button(L10n.tr("usage.hide")) { store.updateSettings { $0.isVisible = false } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("usage.menu"))
    }
}

@MainActor
private struct UsageProviderCell: View {
    @ObservedObject var store: UsageMonitorStore
    let provider: UsageProviderID
    let onOpenSettings: () -> Void
    @Environment(\.usageReduceMotion) private var reduceMotion
    @Environment(\.usageReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var showDetails = false
    @State private var spin: Double = 0
    @FocusState private var isFocused: Bool

    private var isRefreshing: Bool { store.refreshing.contains(provider) }

    private var reading: UsageReading {
        guard store.settings.monitoringEnabled else { return UsageReading(provider: provider, status: .disabled) }
        return store.readings.first { $0.provider == provider } ?? UsageReading(provider: provider)
    }

    private var fraction: Double? {
        guard reading.status != .disabled, reading.status != .notConnected else { return nil }
        if provider == .deepseek {
            guard let usd = reading.localSpend?.today.usd, !usd.isNaN, usd >= 0 else { return nil }
            return NSDecimalNumber(decimal: usd / 100).doubleValue
        }
        return UsagePresentation.fraction(reading.displayedHeadline?.usedFraction)
    }

    private var valueText: String {
        UsagePresentation.percent(fraction)
    }
    private var valueDescription: String {
        "\(L10n.tr(provider == .deepseek ? "usage.spend.today" : "usage.used")) \(valueText)"
    }

    private var tint: Color {
        if (fraction ?? 0) >= 0.7 { return Color(red: 1, green: 63.0 / 255, blue: 0) }
        if (fraction ?? 0) >= 0.5 {
            return colorScheme == .dark ? Color(red: 242.0 / 255, green: 1, blue: 0)
                : Color(red: 176.0 / 255, green: 136.0 / 255, blue: 0)
        }
        return Color(nsColor: .controlAccentColor)
    }

    // The vector PDFs retain a 4% export margin. Undo that before applying the
    // upstream ProviderGlyph optical scale so their visible sizes match its paths.
    private var glyphScale: CGFloat {
        switch provider {
        case .codex: 1.08 * 0.94
        case .claude, .cursor: 1.08 * 0.97
        case .copilot: 1.08 * 0.96
        case .ollama: 1.08 * 0.95
        case .deepseek: 1
        }
    }

    var body: some View {
        let scale = store.settings.scale
        Button { store.refresh(provider) } label: {
            VStack(spacing: UsageNotchLayout.ringLabelGap * scale) {
                // CodeNotch ProviderRing's quota-only layers, with its stroke insets.
                ZStack {
                    Circle().strokeBorder(colorScheme == .dark ? .white.opacity(0.188) : .black.opacity(0.16),
                                          lineWidth: UsageNotchLayout.trackStroke * scale)
                    if let fraction {
                        Circle()
                            .inset(by: UsageNotchLayout.trackStroke * scale / 2)
                            .trim(from: 0, to: min(fraction, 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: UsageNotchLayout.progressStroke * scale, lineCap: .round))
                            .rotationEffect(.degrees(-90 + spin))
                            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86), value: fraction)
                    }
                    UsageProviderGlyph(provider: provider)
                        .frame(width: UsageNotchLayout.glyphSize * scale, height: UsageNotchLayout.glyphSize * scale)
                        .scaleEffect(glyphScale)
                        .opacity((fraction ?? 0) >= 1 ? (reduceTransparency ? 0.7 : 0.35) : 1)
                }
                .frame(width: UsageNotchLayout.ringDiameter * scale, height: UsageNotchLayout.ringDiameter * scale)
                .opacity(reading.status == .ready ? 1 : (reduceTransparency ? 0.75 : 0.45))
                .scaleEffect(isRefreshing ? 0.93 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.62), value: isRefreshing)
                Text(valueText)
                    .font(.system(size: UsageNotchLayout.percentFontSize * scale, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86), value: valueText)
                    .frame(height: UsageNotchLayout.percentLineHeight * scale)
            }
            .frame(width: UsageNotchLayout.ringDiameter * scale, height: UsageNotchLayout.cellExtent * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Original ProviderRing: one finite turn, never a repeatForever spinner that can outlive work.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) { spin += 360 }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10 * scale)
                .stroke(.white.opacity(isFocused ? 0.8 : 0), lineWidth: 1)
                .padding(4 * scale)
                .allowsHitTesting(false)
        }
        .onKeyPress(.escape) { showDetails = false; return .handled }
        .onChange(of: showDetails) { _, shown in
            if shown { store.refreshBecauseSomeoneIsLooking() }
        }
        .onChange(of: store.settings.isVisible) { _, visible in
            if !visible { showDetails = false }
        }
        .help("\(provider.displayName) · \(UsagePresentation.status(reading.status)) · \(valueDescription)")
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(isRefreshing ? L10n.tr("usage.refreshing") : "\(valueDescription), \(UsagePresentation.status(reading.status))")
        .accessibilityHint(L10n.tr("usage.details_hint"))
        .accessibilityAction(named: Text(L10n.tr("usage.show_details"))) { showDetails = true }
        .background {
            if provider == .codex {
                UsageHoverCard(isPresented: $showDetails, edge: store.settings.edge,
                               surfaceStyle: store.settings.surfaceStyle, reduceTransparency: reduceTransparency) { tailOffset in
                    UsageCodexReadingDetail(store: store, tailOffset: tailOffset)
                        .environment(\.colorScheme, colorScheme)
                        .environment(\.usageReduceTransparency, reduceTransparency)
                        .environment(\.usageTooltipSurfaceStyle, store.settings.surfaceStyle)
                }
            } else {
                UsageHoverPopover(isPresented: $showDetails, edge: store.settings.edge, reduceMotion: reduceMotion) {
                    UsageReadingDetail(store: store, provider: provider, onOpenSettings: onOpenSettings)
                        .environment(\.colorScheme, colorScheme)
                }
            }
        }
    }
}

@MainActor
private struct UsageSettingsOrb: View {
    let edge: UsageBarEdge
    let scale: CGFloat
    let surfaceStyle: UsageBarSurfaceStyle
    let opacity: Double
    let action: () -> Void
    @Environment(\.usageReduceMotion) private var reduceMotion
    @Environment(\.usageReduceTransparency) private var reduceTransparency
    @State private var hovered = false
    @State private var spins = 0

    var body: some View {
        Button {
            spins += 1
            action()
        } label: {
            ZStack {
                UsageNotchSurface(style: surfaceStyle)
                    .clipShape(UsageNotchSettingsArc(edge: edge))
                    .opacity(hovered ? 0 : (reduceTransparency ? 1 : opacity))
                    .scaleEffect(hovered ? 0.86 : 1)
                UsageNotchSurface(style: surfaceStyle, interactive: true)
                    .clipShape(Circle())
                    .frame(width: UsageNotchLayout.orbDiameter * scale, height: UsageNotchLayout.orbDiameter * scale)
                    .opacity(hovered ? (reduceTransparency ? 1 : opacity) : 0)
                    .scaleEffect(hovered ? 1 : 1.1)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: UsageNotchLayout.px(56) * scale))
                    .opacity(hovered ? 1 : 0)
                    .scaleEffect(hovered ? 1 : 0.5)
                    .rotationEffect(.degrees((hovered ? 0 : -60) + Double(spins) * 360))
                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.72), value: spins)
            }
            .frame(width: 2 * UsageNotchLayout.curlRadius * scale, height: 2 * UsageNotchLayout.curlRadius * scale)
            .background {
                UsageHoverTracking { hovered = $0 }
                    .frame(width: 2 * UsageNotchLayout.orbExtent * scale, height: 2 * UsageNotchLayout.orbExtent * scale)
            }
            .contentShape(Circle().inset(by: (UsageNotchLayout.curlRadius - UsageNotchLayout.orbExtent) * scale))
            .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.7), value: hovered)
        }
        .buttonStyle(.plain)
        .help(L10n.tr("usage.settings"))
        .accessibilityLabel(L10n.tr("usage.settings"))
    }
}

@MainActor
private struct UsageReadingDetail: View {
    @ObservedObject var store: UsageMonitorStore
    let provider: UsageProviderID
    let onOpenSettings: () -> Void

    private var reading: UsageReading {
        guard store.settings.monitoringEnabled else { return UsageReading(provider: provider, status: .disabled) }
        return store.readings.first { $0.provider == provider } ?? UsageReading(provider: provider)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(provider.displayName).font(.headline)
                        Spacer()
                        Text(UsagePresentation.status(reading.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    if reading.status == .disabled {
                        Text(L10n.tr("usage.off_hint")).font(.callout)
                    } else {
                        if provider == .deepseek {
                            UsageLocalSpendDetail(spend: reading.localSpend)
                        } else if reading.limits.isEmpty && reading.detail == nil {
                            Text(L10n.tr("usage.no_reading")).foregroundStyle(.secondary)
                        }
                        ForEach(reading.limits) { limit in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(limit.title).font(.subheadline.weight(.medium))
                                Text("\(L10n.tr("usage.used")) \(UsagePresentation.percent(limit.usedFraction))")
                                    .monospacedDigit()
                                if let reset = limit.resetsAt {
                                    Text(UsagePresentation.countdown(to: reset, now: context.date))
                                    Text(reset.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                        if let detail = reading.detail, !detail.isEmpty {
                            Text(UsagePresentation.detail(detail)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let updated = reading.updatedAt {
                            HStack(spacing: 4) {
                                Text(L10n.tr("usage.updated"))
                                Text(updated, style: .relative)
                                Text(L10n.tr("usage.ago"))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            Text(updated.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(L10n.tr("usage.never_updated")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = store.settingsError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    }
                    Divider()
                    HStack {
                        Button(store.refreshing.contains(provider) ? L10n.tr("usage.refreshing") : L10n.tr("usage.refresh")) { store.refresh(provider) }
                            .disabled(!store.settings.monitoringEnabled || store.refreshing.contains(provider))
                        Spacer()
                        Button(L10n.tr("usage.settings"), action: onOpenSettings)
                    }
                }
                .padding(16)
            }
            .frame(width: 320, height: 360)
        }
    }
}

@MainActor
struct UsageLocalSpendDetail: View {
    var spend: UsageLocalSpend?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("usage.spend.estimate")).font(.subheadline.weight(.medium))
            LabeledContent(L10n.tr("usage.spend.today"), value: UsagePresentation.budgetPercent(spend?.today.usd))
            LabeledContent(L10n.tr("usage.spend.last7days"), value: UsagePresentation.budgetPercent(spend?.last7Days.usd))
            LabeledContent(L10n.tr("usage.spend.last30days"), value: UsagePresentation.budgetPercent(spend?.last30Days.usd))
            if let spend {
                Text(String(format: L10n.tr("usage.spend.scan"), spend.scannedFiles, spend.discoveredFiles, spend.total.records))
                    .foregroundStyle(.secondary)
                if spend.total.records == 0 {
                    Text(L10n.tr(spend.discoveredFiles == 0 ? "usage.spend.no_logs" : "usage.spend.no_records"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: L10n.tr("usage.spend.sources"), spend.total.recorded, spend.total.configured,
                                spend.total.reference, spend.total.unpriced))
                        .foregroundStyle(.secondary)
                    if spend.total.reference > 0 {
                        Text(L10n.tr("usage.spend.reference")).foregroundStyle(.secondary)
                    }
                }
            }
            if spend?.incomplete == true {
                Label(L10n.tr("usage.spend.incomplete"), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit()
    }
}

@MainActor
private struct UsageCodexReadingDetail: View {
    @ObservedObject var store: UsageMonitorStore
    var tailOffset: CGFloat
    private var reading: UsageReading {
        guard store.settings.monitoringEnabled else { return UsageReading(provider: .codex, status: .disabled) }
        return store.readings.first { $0.provider == .codex } ?? UsageReading(provider: .codex)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            UsageCodexTooltip(reading: reading, now: context.date,
                              direction: store.settings.edge == .top ? .down : .up, tailOffset: tailOffset)
        }
    }
}

/// Codex uses the original glass silhouette, not an NSPopover's extra chrome/arrow.
@MainActor
struct UsageHoverCard<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let edge: UsageBarEdge
    let surfaceStyle: UsageBarSurfaceStyle
    let reduceTransparency: Bool
    @ViewBuilder let content: (CGFloat) -> Content

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.setPresented = { if isPresented != $0 { isPresented = $0 } }
        view.edge = edge
        view.panel.appearance = surfaceStyle.panelAppearance(reduceTransparency: reduceTransparency)
        view.renderContent = { [weak view] tailOffset in
            AnyView(content(tailOffset).background {
                UsageHoverTracking { [weak view] inside in
                    if inside { view?.cancelClose() } else { view?.scheduleClose() }
                }
            })
        }
        if isPresented { view.present() } else { view.close() }
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.close()
        view.renderContent = { _ in AnyView(EmptyView()) }
        view.setPresented = { _ in }
    }

    final class Anchor: UsageHoverTrackingView {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        var setPresented: (Bool) -> Void = { _ in }
        var renderContent: (CGFloat) -> AnyView = { _ in AnyView(EmptyView()) }
        var edge: UsageBarEdge = .top
        private var closeTask: Task<Void, Never>?
        private var hasContent = false
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false; panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = host
        }
        required init?(coder: NSCoder) { nil }
        override func mouseEntered(with event: NSEvent) { cancelClose(); setPresented(true); present() }
        override func mouseExited(with event: NSEvent) { scheduleClose() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { close() }
        }
        func present() {
            guard let window, window.isVisible, let screen = window.screen else { close(); return }
            host.rootView = renderContent(0)
            hasContent = true
            let size = host.fittingSize
            let cell = window.convertToScreen(convert(bounds, to: nil))
            let x = min(max(cell.midX - size.width / 2, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
            let y = edge == .top ? window.frame.minY - UsageTooltipLayout.tailGap - size.height
                : window.frame.maxY + UsageTooltipLayout.tailGap
            host.rootView = renderContent(cell.midX - x - size.width / 2)
            panel.setFrame(NSRect(x: x, y: min(max(y, screen.frame.minY + 4), screen.frame.maxY - size.height - 4),
                                  width: size.width, height: size.height), display: true)
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
            panel.orderFrontRegardless()
        }
        func close() {
            cancelClose()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            // Hiding a window alone leaves its SwiftUI timelines and graphs alive.
            if hasContent {
                host.rootView = AnyView(EmptyView())
                hasContent = false
            }
        }
        func cancelClose() { closeTask?.cancel(); closeTask = nil }
        func scheduleClose() {
            cancelClose()
            closeTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                if self.panel.frame.contains(NSEvent.mouseLocation) { return }
                self.close(); self.setPresented(false)
            }
        }
    }
}

/// Shared native tracking for the settings handle, provider cells and popover buttons.
@MainActor
private struct UsageHoverTracking: NSViewRepresentable {
    let onHover: (Bool) -> Void
    func makeNSView(context: Context) -> UsageHoverTrackingView { UsageHoverTrackingView(frame: .zero) }
    func updateNSView(_ view: UsageHoverTrackingView, context: Context) { view.onHover = onHover }
    static func dismantleNSView(_ view: UsageHoverTrackingView, coordinator: ()) { view.onHover = { _ in } }
}

@MainActor
class UsageHoverTrackingView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// SwiftUI hover tracking is not sufficient for an inactive, nonactivating NSPanel.
/// Track in activeAlways mode, and present a real popover without activating the app.
@MainActor
struct UsageHoverPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let edge: UsageBarEdge
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.setPresented = { if isPresented != $0 { isPresented = $0 } }
        view.edge = edge == .top ? .minY : .maxY
        view.popover.animates = !reduceMotion
        view.popover.appearance = view.window?.effectiveAppearance
        view.renderContent = { [weak view] in
            AnyView(content().background {
                UsageHoverTracking { [weak view] inside in
                    if inside { view?.cancelClose() } else { view?.scheduleClose() }
                }
            })
        }
        if isPresented { view.present() } else { view.close() }
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.close()
        view.clearContent()
        view.renderContent = { AnyView(EmptyView()) }
        view.setPresented = { _ in }
    }

    final class Anchor: UsageHoverTrackingView, NSPopoverDelegate {
        let popover = NSPopover()
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        var setPresented: (Bool) -> Void = { _ in }
        var renderContent: () -> AnyView = { AnyView(EmptyView()) }
        var edge: NSRectEdge = .minY
        private var closeTask: Task<Void, Never>?
        private var hasContent = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            popover.contentViewController = host
            popover.behavior = .transient
            popover.delegate = self
        }

        required init?(coder: NSCoder) { nil }
        override func mouseEntered(with event: NSEvent) {
            cancelClose()
            setPresented(true)
            present()
        }
        override func mouseExited(with event: NSEvent) { scheduleClose() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { close() }
        }

        func present() {
            guard let window, window.isVisible else { close(); return }
            host.rootView = renderContent()
            hasContent = true
            if !popover.isShown { popover.show(relativeTo: bounds, of: self, preferredEdge: edge) }
        }

        func close() {
            cancelClose()
            if popover.isShown { popover.performClose(nil) } else { clearContent() }
        }
        func clearContent() {
            if hasContent {
                host.rootView = AnyView(EmptyView())
                hasContent = false
            }
        }
        func cancelClose() { closeTask?.cancel(); closeTask = nil }
        func scheduleClose() {
            cancelClose()
            closeTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                // Crossing the gap to the popover must not dismiss its refresh/settings buttons.
                if let frame = self.host.view.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
                self.close()
                self.setPresented(false)
            }
        }

        func popoverDidClose(_ notification: Notification) {
            cancelClose()
            clearContent()
            setPresented(false)
        }
    }
}
