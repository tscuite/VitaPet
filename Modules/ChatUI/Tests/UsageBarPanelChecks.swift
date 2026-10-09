// Isolated executable check, not part of production UI. Compile the real three Usage*.swift
// sources as ChatUI and the real UsageMonitor module with -enable-testing,
// then compile this file and UsageBarController with -D USAGE_PANEL_CHECKS.
// Run scripts/check_usage_ui.sh after the release build. No live credentials or network.
#if USAGE_PANEL_CHECKS
import AppKit
import SwiftUI
import Localization
@testable import UsageMonitor
@testable import ChatUI

@MainActor
final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private actor FixtureReads {
    private var counts: [UsageProviderID: Int] = [:]
    func record(_ provider: UsageProviderID) { counts[provider, default: 0] += 1 }
    func snapshot() -> [UsageProviderID: Int] { counts }
}

@MainActor
private final class HoverProbe: ObservableObject {
    @Published var presented = false
    @Published var revision = 0
    var builds = 0
    weak var lastContent: HoverContentLifetime?

    func content(revision: Int) -> HoverProbeContent {
        builds += 1
        let lifetime = HoverContentLifetime()
        lastContent = lifetime
        return HoverProbeContent(lifetime: lifetime, revision: revision)
    }
}

@MainActor
private final class HoverContentLifetime {
    var ticks = 0
}

@MainActor
private struct HoverProbeContent: View {
    let lifetime: HoverContentLifetime
    let revision: Int
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let _ = lifetime.ticks += 1
            Text("Offline lifecycle probe \(revision)").frame(width: 200, height: 100)
        }
    }
}

@MainActor
private struct HoverProbeFixture: View {
    @ObservedObject var probe: HoverProbe
    let card: Bool
    var body: some View {
        let revision = probe.revision
        Group {
            if card {
                UsageHoverCard(isPresented: $probe.presented, edge: .top,
                               surfaceStyle: .solid, reduceTransparency: true) { _ in
                    probe.content(revision: revision)
                }
            } else {
                UsageHoverPopover(isPresented: $probe.presented, edge: .top, reduceMotion: true) {
                    probe.content(revision: revision)
                }
            }
        }.frame(width: 44, height: 44)
    }
}

@main
struct UsageBarPanelChecks {
    @MainActor private static func checkPointerHitTesting() {
        let font = NSFont.systemFont(ofSize: UsageNotchLayout.percentFontSize, weight: .semibold)
        precondition(UsageNotchLayout.percentLineHeight == ceil(font.ascender - font.descender + font.leading),
                     "Cached line height must equal the native fixed-font measurement")
        let settings = UsageBarSettings()
        let start = ProcessInfo.processInfo.systemUptime
        var hits = 0
        for index in 0..<100_000 {
            let point = CGPoint(x: 2000 + index % 100, y: 1000 + index % 50)
            if UsageBarView.containsInteraction(at: point, settings: settings) { hits += 1 }
        }
        precondition(hits == 0)
        FileHandle.standardOutput.write(Data(String(format: "Outside-strip hit-test fixture: 100000 queries in %.1f ms\n",
                     (ProcessInfo.processInfo.systemUptime - start) * 1000).utf8))
        for providers in [[], [.codex], UsageProviderID.allCases] {
            for edge in UsageBarEdge.allCases {
                for scale in [0.6, 1.0, 1.8] {
                    var settings = settings
                    settings.providers = providers; settings.edge = edge; settings.scale = scale
                    let width = UsageNotchLayout.shapeLength(count: max(1, providers.count)) * scale
                    let height = UsageNotchLayout.bodyDepth * scale
                    let radius = UsageNotchLayout.orbExtent * scale
                    let bounds = CGRect(x: 0, y: 0, width: width + radius, height: height)
                    let path = UsageNotchShape(edge: edge, scale: scale)
                        .path(in: CGRect(x: 0, y: 0, width: width, height: height))
                    let bleed = edge == .top ? -UsageNotchLayout.bezelBleed : UsageNotchLayout.bezelBleed
                    let orbY = edge == .top ? UsageNotchLayout.curlRadius * scale : height - UsageNotchLayout.curlRadius * scale
                    for x in stride(from: -10.0, through: bounds.width + 10, by: 7) {
                        for y in [-1.0, 0, 1, height / 2, height - 1, height, height + 1] {
                            let point = CGPoint(x: x, y: y)
                            let expected = bounds.contains(point) &&
                                (path.contains(CGPoint(x: x, y: y - bleed)) || hypot(x - width, y - orbY) <= radius)
                            precondition(UsageBarView.containsInteraction(at: point, settings: settings) == expected,
                                         "Hit testing must match the clipped outline/orb: \(edge), \(scale), \(point)")
                        }
                    }
                }
            }
        }
        print("PASS: pointer bounds match the clipped outline/orb at both edges, scales and provider counts")
    }

    @MainActor private static func checkHoverLifetime() async {
        for card in [true, false] {
            let kind = card ? "card" : "popover"
            let probe = HoverProbe()
            let host = NSHostingView(rootView: AnyView(HoverProbeFixture(probe: probe, card: card)))
            let panel = PreviewPanel(contentRect: NSRect(x: 100, y: 450, width: 44, height: 44),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.orderFrontRegardless()
            try! await Task.sleep(for: .milliseconds(200))
            precondition(probe.builds == 0, "Hidden \(kind) must not build a SwiftUI detail graph")
            for _ in 0..<2 {
                probe.presented = true
                try! await Task.sleep(for: .milliseconds(200))
                precondition((probe.lastContent?.ticks ?? 0) > 0, "Visible \(kind) must run its timeline")
                let builds = probe.builds
                probe.revision += 1
                try! await Task.sleep(for: .milliseconds(150))
                precondition(probe.builds > builds, "Visible \(kind) must update content")
                probe.presented = false
                try! await Task.sleep(for: .milliseconds(300))
                precondition(probe.lastContent == nil, "Closed \(kind) must release its content and timeline")
                let closedBuilds = probe.builds
                probe.revision += 1
                try! await Task.sleep(for: .milliseconds(150))
                precondition(probe.builds == closedBuilds, "Hidden \(kind) updates must stay lazy")
            }
            probe.presented = true
            try! await Task.sleep(for: .milliseconds(200))
            precondition(probe.lastContent != nil)
            panel.contentView = nil
            try! await Task.sleep(for: .milliseconds(300))
            precondition(probe.lastContent == nil, "Detached \(kind) must release its content")
            panel.contentView = host
            probe.presented = true // A transient popover resets its binding when detached; hover again.
            try! await Task.sleep(for: .milliseconds(200))
            precondition(probe.lastContent != nil, "Reopened \(kind) after reattachment must present fresh content")
            host.rootView = AnyView(EmptyView())
            try! await Task.sleep(for: .milliseconds(300))
            precondition(probe.lastContent == nil, "Dismantled \(kind) must release its content")
            panel.close()
        }
        print("PASS: hidden hover content stays lazy; visible updates, close/reopen, detach/reattach and dismantle release timeline graphs")
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Hardware hover must not race the fixture's direct enter/exit events; native clicks still pass through.
        let hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { _ in nil }
        defer { if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) } }
        checkPointerHitTesting()
        L10n.locale = "en"
        let glyphBundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("VitaPet_ChatUI.bundle"))!
        for provider in UsageProviderID.allCases {
            let asset = glyphBundle.url(forResource: provider.rawValue, withExtension: "pdf", subdirectory: "UsageGlyphs")!
            precondition(NSImage(contentsOf: asset) != nil, "Missing native provider glyph")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("UsageBarPanelChecks-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = output.appendingPathComponent("fixture-settings")
        print("Fixture artifacts: \(output.path)")
        let values: [UsageProviderID: Double] = [.cursor: 0.99, .ollama: 0.005]
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("UsageMonitor/Tests/Fixtures")
        var codexFixture = try! UsageParsing.parse(Data(contentsOf: fixtures.appendingPathComponent("codex-usage.json")),
            provider: .codex, now: fixedNow,
            codexSettings: UsageCodexSettings(showExtraLimits: false, resetTimeFormat: .remaining, showUsagePace: true))
        codexFixture.tokenUsage = try! CodexUsage.profileUsage(from: Data(contentsOf: fixtures.appendingPathComponent("codex-profile.json")))
        codexFixture.resetCredits = try! CodexUsage.resetCredits(from: Data(contentsOf: fixtures.appendingPathComponent("codex-resets.json")))
        let codexReading = codexFixture
        precondition(UsageTooltipLayout.cardBodyFont.pointSize >= 12 && UsageTooltipLayout.titleFontSize >= 15,
                     "Codex detail text must use readable native-point sizes, independent of strip scale")
        for locale in ["en", "zh-Hans"] {
            L10n.locale = locale
            for limit in codexReading.limits {
                var summary = UsageTooltipCopy.summary(limit)
                if let pace = limit.usagePace(now: fixedNow) {
                    summary += " · " + UsageTooltipCopy.format(pace.isDeficit ? "usage.codex.deficit" : "usage.codex.reserved", pace.value)
                }
                let width = (summary as NSString).size(withAttributes: [.font: UsageTooltipLayout.cardBodyFont]).width
                precondition(width <= UsageTooltipLayout.cardWidth - 2 * UsageTooltipLayout.cardPadding,
                             "Bilingual quota/pace text must fit without shrinking: \(locale), \(limit.id)")
            }
        }
        L10n.locale = "en"
        let copilotReading = try! UsageParsing.parse(Data(contentsOf: fixtures.appendingPathComponent("copilot-usage.json")),
            provider: .copilot, now: fixedNow)
        let spendFixture = UsageLocalSpend(today: .init(usd: Decimal(string: "57.35"), records: 3, reference: 3),
            last7Days: .init(usd: Decimal(string: "87.23"), records: 15, recorded: 10, reference: 5),
            last30Days: .init(usd: Decimal(string: "127.35"), records: 40, recorded: 30, reference: 10),
            total: .init(usd: 180, records: 60, recorded: 40, configured: 5, reference: 15),
            scannedFiles: 202, discoveredFiles: 202)
        let reads = FixtureReads()
        let store = UsageMonitorStore(directory: directory, fetch: { provider in
            await reads.record(provider)
            if provider == .codex { return codexReading }
            if provider == .copilot { return copilotReading }
            if provider == .deepseek { return UsageReading(provider: provider, status: .ready, updatedAt: Date(), localSpend: spendFixture) }
            return UsageReading(provider: provider, status: .ready,
                limits: [UsageLimit(id: "fixture", title: "Fixture window", usedFraction: values[provider], resetsAt: Date().addingTimeInterval(3660))],
                updatedAt: Date(), detail: "Isolated test fixture — no account access")
        })
        let panel = PreviewPanel(contentRect: NSRect(x: 120, y: 240, width: 386, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true // Match the real UsageBarPanel's mouse/focus policy.
        let host = NSHostingView(rootView: AnyView(UsageBarView(store: store, onOpenSettings: {})))
        panel.contentView = host
        panel.orderFrontRegardless()

        @discardableResult func capture(_ name: String, _ view: NSView) -> Data {
            if view === host { panel.setContentSize(host.fittingSize) }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            try! data.write(to: output.appendingPathComponent("\(name).png"))
            print("Captured \(name): \(view.bounds.width) × \(view.bounds.height)")
            return data
        }
        func anchors(_ view: NSView) -> [NSView] {
            ([view].filter { String(describing: type(of: $0)).contains("Anchor") }) + view.subviews.flatMap(anchors)
        }
        func trackingViews(_ view: NSView) -> [NSView] {
            ([view].filter { String(describing: type(of: $0)).contains("UsageHoverTrackingView") }) + view.subviews.flatMap(trackingViews)
        }
        func click(_ anchor: NSView, in window: NSWindow) {
            let point = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            }
            // Queue mouse-up first in case native button tracking enters a nested event loop.
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            window.sendEvent(event(.leftMouseDown))
        }
        Task { @MainActor in
            await checkHoverLifetime()
            try! await Task.sleep(for: .milliseconds(300))
            capture("strip-off", host)
            store.updateSettings { $0.monitoringEnabled = true }
            store.start()
            try! await Task.sleep(for: .milliseconds(500))
            precondition(store.readings.count == 5 && store.readings.allSatisfy { $0.status == .ready })
            panel.appearance = NSAppearance(named: .darkAqua)
            try! await Task.sleep(for: .milliseconds(200))
            let stripFixtureData = capture("strip-fixture", host)
            let stripBitmap = NSBitmapImageRep(data: stripFixtureData)!
            var deepseekAmber = 0
            for y in 0..<stripBitmap.pixelsHigh {
                for x in 0..<stripBitmap.pixelsWide {
                    guard let color = stripBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // Today's 57% is amber; the distinct 7/30-day values are red. Allow color-managed edge pixels.
                    if color.redComponent > 0.85, color.greenComponent > 0.9, color.blueComponent < 0.75,
                       color.redComponent - color.blueComponent > 0.25 {
                        deepseekAmber += 1
                    }
                }
            }
            precondition(deepseekAmber > 30, "DeepSeek 57% of the $100 budget must draw an amber arc in the dark fixture")
            precondition(abs(host.bounds.height - UsageNotchLayout.bodyDepth) < 1, "Original horizontal notch depth")
            precondition(abs(host.bounds.width - UsageNotchLayout.shapeLength(count: 5) - UsageNotchLayout.orbExtent) < 1, "Original spacing plus settings handle")
            precondition(UsageNotchLayout.ringDiameter == 44, "Original 44pt rings")
            for edge in UsageBarEdge.allCases {
                let rect = CGRect(x: 0, y: 0, width: 468, height: UsageNotchLayout.bodyDepth)
                let path = UsageNotchShape(edge: edge).path(in: rect)
                let nearBezel = CGPoint(x: 4, y: edge == .top ? 1 : rect.height - 1)
                let farCorner = CGPoint(x: 4, y: edge == .top ? rect.height - 1 : 1)
                precondition(path.contains(nearBezel) && !path.contains(farCorner), "Inverse flare, not a rounded floating card")
            }
            panel.appearance = NSAppearance(named: .aqua)
            try! await Task.sleep(for: .milliseconds(200))
            capture("strip-light", host)
            panel.appearance = NSAppearance(named: .darkAqua)
            let hoverAnchors = anchors(host)
            precondition(hoverAnchors.count == 5, "Expected five native hover anchors")
            for anchor in hoverAnchors {
                anchor.updateTrackingAreas()
                precondition(anchor.trackingAreas.contains { $0.options.contains(.activeAlways) })
            }
            app.deactivate()
            try! await Task.sleep(for: .milliseconds(300))
            precondition(!app.isActive, "Harness must test an inactive application")
            let initialReads = await reads.snapshot()
            let restingRing = capture("click-rest", host)
            click(hoverAnchors[0], in: panel)
            try! await Task.sleep(for: .milliseconds(120))
            precondition(store.refreshing == [.codex], "Native icon click must refresh exactly one source, not merely toggle details")
            let clickedReads = await reads.snapshot()
            precondition(clickedReads[.codex] == initialReads[.codex, default: 0] + 1)
            precondition(clickedReads.filter { $0.key != .codex } == initialReads.filter { $0.key != .codex }, "Click must not spend other sources' request budgets")
            let pressedRing = capture("click-refresh", host)
            precondition(pressedRing != restingRing, "Refresh feedback must be drawn on the real cell")
            click(hoverAnchors[0], in: panel)
            try! await Task.sleep(for: .milliseconds(100))
            let repeatedReads = await reads.snapshot()
            precondition(repeatedReads == clickedReads, "Native double click cannot queue another fetch")
            try! await Task.sleep(for: .milliseconds(1000))
            precondition(store.refreshing.isEmpty && !app.isActive,
                         "Finite feedback settles without activation: refreshing=\(store.refreshing), active=\(app.isActive)")
            capture("click-settled", host)
            print("PASS: native inactive-panel mouse-down/up triggers one-source refresh, visible finite feedback and rapid-click deduplication")
            let before = app.windows.filter(\.isVisible).count
            let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            hoverAnchors[0].mouseEntered(with: event)
            try! await Task.sleep(for: .milliseconds(400))
            let after = app.windows.filter(\.isVisible).count
            precondition(after > before, "Native hover must create a visible popover: before=\(before), after=\(after), active=\(app.isActive)")
            precondition(!app.isActive, "Hover must not activate the app")
            print("PASS: activeAlways anchors and hover-triggered visible popover on an inactive nonactivating panel")
            if let popover = app.windows.first(where: { $0 !== panel && $0.isVisible }), let content = popover.contentView {
                capture("hover-detail", content)
                precondition(abs(content.bounds.width - UsageTooltipLayout.cardWidth) < 1, "Readable fixed-width Codex card, independent of the strip scale")
                precondition(content.bounds.height > 300, "Account statistics must not be replaced by a fixed-height summary")
                let detailTracking = trackingViews(content)
                precondition(detailTracking.count == 1, "Popover buttons need native inactive-window tracking")
                hoverAnchors[0].mouseExited(with: event)
                detailTracking[0].mouseEntered(with: event)
                try! await Task.sleep(for: .milliseconds(350))
                precondition(popover.isVisible, "Crossing to popover buttons must cancel delayed close")
                detailTracking[0].mouseExited(with: event)
            }
            try! await Task.sleep(for: .milliseconds(400))
            // Render the same response with a fixed clock so all original fields/chart are visible.
            let cardHost = NSHostingView(rootView: AnyView(EmptyView()))
            let cardPanel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            cardPanel.isOpaque = false; cardPanel.backgroundColor = .clear; cardPanel.isReleasedWhenClosed = false
            cardPanel.becomesKeyOnlyIfNeeded = true
            cardPanel.contentView = cardHost
            cardPanel.setFrameOrigin(NSPoint(x: 600, y: 300)); cardPanel.orderFrontRegardless()
            for locale in ["en", "zh-Hans"] {
                L10n.locale = locale
                for style in UsageBarSurfaceStyle.allCases {
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        cardPanel.appearance = style.panelAppearance(reduceTransparency: false) ?? NSAppearance(named: appearance)
                        cardHost.rootView = AnyView(UsageCodexTooltip(reading: codexReading, now: fixedNow)
                            .environment(\.usageTooltipSurfaceStyle, style))
                        cardPanel.setContentSize(cardHost.fittingSize)
                        try! await Task.sleep(for: .milliseconds(120))
                        precondition(abs(cardHost.bounds.width - UsageTooltipLayout.cardWidth) < 1)
                        capture("codex-\(locale)-\(style.rawValue)-\(appearance.rawValue)", cardHost)
                    }
                }
            }
            L10n.locale = "en"
            var extras = try! UsageParsing.parse(Data(contentsOf: fixtures.appendingPathComponent("codex-usage.json")), provider: .codex, now: fixedNow)
            extras.tokenUsage = codexReading.tokenUsage; extras.resetCredits = codexReading.resetCredits
            cardHost.rootView = AnyView(UsageCodexTooltip(reading: extras, now: fixedNow, direction: .up, tailOffset: 40)
                .environment(\.usageTooltipSurfaceStyle, .solid)
                .environment(\.usageReduceTransparency, true))
            cardPanel.appearance = NSAppearance(named: .darkAqua)
            cardPanel.setContentSize(cardHost.fittingSize)
            try! await Task.sleep(for: .milliseconds(150))
            capture("codex-extra-limits-up-reduced-transparency", cardHost)
            precondition(extras.limits.count == 6 && Set(extras.limits.compactMap(\.group)) == ["Spark", "Code review"])
            let empty = UsageCodexTooltip(reading: UsageReading(provider: .codex), now: fixedNow)
            cardHost.rootView = AnyView(empty.environment(\.usageTooltipSurfaceStyle, .solid))
            cardPanel.setContentSize(cardHost.fittingSize)
            capture("codex-not-connected", cardHost)
            print("PASS: original Codex quota/used-left/pace, plan, reset-credit and token-stat/chart card; bilingual themes, grouped extras, top/bottom tail and empty state")
            let copilotCases: [(String, String, Double?)] = [
                ("metered", #"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":20}}}"#, 0.8),
                ("chat-fallback", #"{"quota_snapshots":{"premium_interactions":{"unlimited":true},"chat":{"percent_remaining":20}}}"#, 0.8),
                ("unused", #"{"quota_snapshots":{"premium_interactions":{"percent_remaining":100}}}"#, 0),
                ("exhausted", #"{"quota_snapshots":{"premium_interactions":{"percent_remaining":0}}}"#, 1),
                ("unlimited", #"{"quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#, nil),
                ("token-billing", #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100}}}"#, nil),
                ("no-quota", #"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0}}}"#, nil)
            ]
            for (name, json, expected) in copilotCases {
                let reading = try! UsageParsing.parse(Data(json.utf8), provider: .copilot, now: fixedNow)
                let copilotStore = UsageMonitorStore(directory: directory.appendingPathComponent("copilot-" + name), fetch: { _ in reading })
                copilotStore.updateSettings { $0.providers = [.copilot]; $0.monitoringEnabled = true }
                copilotStore.start()
                try! await Task.sleep(for: .milliseconds(150))
                precondition(copilotStore.readings.first?.displayedHeadline?.usedFraction == expected)
                for (locale, appearance) in [("en", NSAppearance.Name.darkAqua), ("zh-Hans", .aqua)] {
                    L10n.locale = locale
                    cardPanel.appearance = NSAppearance(named: appearance)
                    cardHost.rootView = AnyView(UsageBarView(store: copilotStore, onOpenSettings: {})
                        .environment(\.usageReduceMotion, true).id(name + locale))
                    cardPanel.setContentSize(cardHost.fittingSize)
                    try! await Task.sleep(for: .milliseconds(180))
                    let image = capture("copilot-\(locale)-\(name)-strip", cardHost)
                    let bitmap = NSBitmapImageRep(data: image)!
                    var progressPixels = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            // Color-managed caching shifts RGB values; distinguish the warm arc from gray tracks/text.
                            if color.redComponent > 0.8 && color.redComponent - color.greenComponent > 0.35 && color.redComponent - color.blueComponent > 0.5 {
                                progressPixels += 1
                            }
                        }
                    }
                    precondition((expected ?? 0) >= 0.7 ? progressPixels > 30 : progressPixels == 0,
                                 "Parsed Copilot quota must draw a real orange arc only for known high usage: \(name), pixels=\(progressPixels)")
                    let anchor = anchors(cardHost).first!
                    let visibleBefore = Set(app.windows.filter(\.isVisible).map(\.windowNumber))
                    anchor.mouseEntered(with: event)
                    try! await Task.sleep(for: .milliseconds(300))
                    let detailWindow = app.windows.first { $0.isVisible && !visibleBefore.contains($0.windowNumber) }
                    precondition(detailWindow != nil && !app.isActive,
                                 "Copilot diagnostic detail: \(name)/\(locale), visible=\(detailWindow != nil), active=\(app.isActive), preexisting=\(visibleBefore.count)")
                    capture("copilot-\(locale)-\(name)-detail", detailWindow!.contentView!)
                    anchor.mouseExited(with: event)
                    try! await Task.sleep(for: .milliseconds(350))
                }
                await copilotStore.stop()
            }
            print("PASS: real Copilot parser→store→native ring pixels and hover, metered fallback/zero/full/unlimited/token-billed states, bilingual light/dark fixtures")
            var partialSpend = spendFixture
            partialSpend.incomplete = true; partialSpend.total.unpriced = 2; partialSpend.total.records += 2
            partialSpend.scannedFiles = 95
            let unpricedSpend = UsageLocalSpend(today: .init(records: 2, unpriced: 2), total: .init(records: 2, unpriced: 2),
                scannedFiles: 202, discoveredFiles: 202)
            let noMatchSpend = UsageLocalSpend(scannedFiles: 202, discoveredFiles: 202)
            for locale in ["en", "zh-Hans"] {
                L10n.locale = locale
                for (name, spend) in [("priced", spendFixture), ("unknown", UsageLocalSpend()), ("partial", partialSpend),
                                      ("unpriced", unpricedSpend), ("no-match", noMatchSpend)] {
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        cardPanel.appearance = NSAppearance(named: appearance)
                        cardHost.rootView = AnyView(UsageLocalSpendDetail(spend: spend).padding(16).frame(width: 320)
                            .background(Color(nsColor: .windowBackgroundColor)).id(locale + name))
                        cardPanel.setContentSize(cardHost.fittingSize)
                        try! await Task.sleep(for: .milliseconds(120))
                        precondition(abs(cardHost.bounds.width - 320) < 1)
                        capture("deepseek-\(locale)-\(name)-\(appearance.rawValue)", cardHost)
                    }
                }
            }
            for locale in ["en", "zh-Hans"] {
                L10n.locale = locale
                for cached in [false, true] {
                    var blocked = cached ? codexReading : UsageReading(provider: .codex)
                    blocked.status = cached ? .stale : .failed
                    blocked.detail = UsageFailure.googleUnavailable.errorDescription
                    cardHost.rootView = AnyView(UsageCodexTooltip(reading: blocked, now: fixedNow).environment(\.usageTooltipSurfaceStyle, .solid))
                    cardPanel.setContentSize(cardHost.fittingSize)
                    try! await Task.sleep(for: .milliseconds(120))
                    capture("codex-google-blocked-\(locale)-cached-\(cached)", cardHost)
                }
            }
            L10n.locale = "en"
            cardPanel.orderOut(nil)
            let deepseekIndex = store.settings.providers.firstIndex(of: .deepseek)!
            let localBefore = await reads.snapshot()
            click(hoverAnchors[deepseekIndex], in: panel)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(store.refreshing == [.deepseek])
            try! await Task.sleep(for: .milliseconds(400))
            let localAfter = await reads.snapshot()
            precondition(localAfter[.deepseek] == localBefore[.deepseek, default: 0] + 1
                && localAfter.filter { $0.key != .deepseek } == localBefore.filter { $0.key != .deepseek })
            hoverAnchors[deepseekIndex].mouseEntered(with: event)
            try! await Task.sleep(for: .milliseconds(300))
            if let detail = app.windows.first(where: { $0 !== panel && $0.isVisible })?.contentView {
                capture("deepseek-native-hover", detail)
            } else { preconditionFailure("DeepSeek native hover must open its monetary detail") }
            hoverAnchors[deepseekIndex].mouseExited(with: event)
            try! await Task.sleep(for: .milliseconds(400))
            precondition(!app.isActive)
            print("PASS: local spend today/last 7/30 days, unknown/partial totals, bilingual themes, native hover and isolated local refresh")
            let orbTracking = trackingViews(host)
            precondition(orbTracking.count == 1, "Settings arc must have its own native hover target")
            orbTracking[0].updateTrackingAreas()
            precondition(orbTracking[0].trackingAreas.contains { $0.options.contains(.activeAlways) })
            let restingOrb = capture("settings-arc-rest", host)
            orbTracking[0].mouseEntered(with: event)
            try! await Task.sleep(for: .milliseconds(600))
            let hoveredOrb = capture("settings-arc-hover", host)
            precondition(hoveredOrb != restingOrb && !app.isActive, "Native hover must wake the gear without activating the app")
            orbTracking[0].mouseExited(with: event)
            try! await Task.sleep(for: .milliseconds(600))
            for style in UsageBarSurfaceStyle.allCases {
                store.updateSettings { $0.surfaceStyle = style }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    panel.appearance = style.panelAppearance(reduceTransparency: false) ?? NSAppearance(named: appearance)
                    try! await Task.sleep(for: .milliseconds(200))
                    capture("strip-\(style.rawValue)-\(appearance.rawValue)", host)
                }
                precondition(style.panelAppearance(reduceTransparency: true)?.name == .darkAqua)
            }
            host.rootView = AnyView(UsageBarView(store: store, onOpenSettings: {})
                .environment(\.usageReduceTransparency, true)
                .environment(\.usageReduceMotion, true))
            try! await Task.sleep(for: .milliseconds(200))
            capture("strip-reduced-transparency-motion", host)
            let reducedReads = await reads.snapshot()
            click(anchors(host)[0], in: panel)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(store.refreshing == [.codex], "Reduced motion must not disable the click or refresh feedback")
            capture("click-reduced-motion", host)
            try! await Task.sleep(for: .milliseconds(1000))
            let reducedAfter = await reads.snapshot()
            precondition(reducedAfter[.codex] == reducedReads[.codex, default: 0] + 1 && store.refreshing.isEmpty)
            host.rootView = AnyView(UsageBarView(store: store, onOpenSettings: {}))
            print("PASS: native settings hover, popover-button crossing, all surface styles and accessibility fallbacks")
            store.updateSettings { $0.providers = [] }
            try! await Task.sleep(for: .milliseconds(200))
            capture("strip-empty", host)
            await store.stop()
            let failureStore = UsageMonitorStore(directory: directory.appendingPathComponent("failures"), fetch: { provider in
                let status: UsageReadingStatus = provider == .codex ? .stale : provider == .cursor ? .rateLimited : .failed
                return UsageReading(provider: provider, status: status,
                    limits: provider == .codex ? [UsageLimit(id: "cached", title: "Cached fixture", usedFraction: 1.1)] : [],
                    updatedAt: provider == .codex ? Date().addingTimeInterval(-600) : nil,
                    detail: "Sanitized fixture failure")
            })
            failureStore.updateSettings { $0.monitoringEnabled = true; $0.opacity = 0.3; $0.scale = 1.5 }
            failureStore.start()
            host.rootView = AnyView(UsageBarView(store: failureStore, onOpenSettings: {}))
            try! await Task.sleep(for: .milliseconds(300))
            capture("strip-failures-scaled", host)
            await failureStore.stop()
            store.updateSettings { $0.monitoringEnabled = false }
            let settings = NSHostingView(rootView: UsageBarSettingsView(store: store, onResetPosition: {}))
            let settingsWindow = NSWindow(contentRect: NSRect(x: 550, y: 150, width: 640, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentView = settings
            settingsWindow.appearance = NSAppearance(named: .aqua)
            settingsWindow.orderFrontRegardless()
            try! await Task.sleep(for: .milliseconds(300))
            capture("settings-en", settings)
            settingsWindow.appearance = NSAppearance(named: .darkAqua)
            L10n.locale = "zh-Hans"
            settings.rootView = UsageBarSettingsView(store: store, onResetPosition: {})
            try! await Task.sleep(for: .milliseconds(300))
            capture("settings-zh", settings)
            settingsWindow.setContentSize(NSSize(width: 540, height: 480))
            try! await Task.sleep(for: .milliseconds(200))
            capture("settings-minimum", settings)
            settingsWindow.orderOut(nil)
            panel.orderOut(nil)

            // Settings windows may activate the harness; establish inactivity before testing strip startup.
            app.deactivate()
            try! await Task.sleep(for: .milliseconds(200))
            precondition(!app.isActive, "Controller startup must begin in an inactive harness")
            // Exercise the actual app controller with fixture storage, never its default directory.
            store.updateSettings { $0.providers = [.codex, .cursor]; $0.isVisible = true }
            let shell = UsageBarController(store: store)
            shell.start()
            try! await Task.sleep(for: .milliseconds(200))
            let shellPanel = app.windows.first { String(describing: type(of: $0)) == "UsageBarPanel" }!
            precondition(shellPanel.isVisible && !app.isActive,
                         "Strip startup must not activate the app: visible=\(shellPanel.isVisible), active=\(app.isActive)")
            precondition(shellPanel.frame.width > 100 && shellPanel.frame.height > 30, "Native shell must measure the strip")
            precondition(shellPanel.level == .statusBar && !shellPanel.hasShadow, "CodeNotch panel level and shadow")
            precondition(NSScreen.screens.contains { abs($0.frame.maxY - shellPanel.frame.maxY) < 0.01 }, "Attached to physical screen top, not visibleFrame below menu bar")
            precondition(shellPanel.appearance?.name == .darkAqua, "Solid black must pin native appearance as well as SwiftUI ink")
            let clearCorner = NSPoint(x: 3, y: shellPanel.frame.height - 1)
            let center = NSPoint(x: shellPanel.frame.width / 2, y: shellPanel.frame.height / 2)
            let shellHost = shellPanel.contentView!
            precondition(shellHost.hitTest(shellHost.convert(clearCorner, to: shellHost.superview)) == nil, "Transparent flare must not intercept a click")
            precondition(shellHost.hitTest(shellHost.convert(center, to: shellHost.superview)) != nil, "Visible chrome must remain interactive")
            shell.updatePointerRouting(at: NSPoint(x: shellPanel.frame.minX + clearCorner.x, y: shellPanel.frame.maxY - clearCorner.y))
            precondition(shellPanel.ignoresMouseEvents, "Pointer in a transparent pocket must pass through to the underlying app")
            shell.updatePointerRouting(at: NSPoint(x: shellPanel.frame.minX + center.x, y: shellPanel.frame.maxY - center.y))
            precondition(!shellPanel.ignoresMouseEvents, "Returning to visible chrome must restore clicks")
            store.updateSettings { $0.monitoringEnabled = true }
            try! await Task.sleep(for: .milliseconds(500))
            let shellBefore = await reads.snapshot()
            click(anchors(shellHost)[0], in: shellPanel)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(store.refreshing == [.codex], "Actual UsageBarController hosting view must route icon clicks")
            try! await Task.sleep(for: .milliseconds(1000))
            let shellAfter = await reads.snapshot()
            precondition(shellAfter[.codex] == shellBefore[.codex, default: 0] + 1 && shellAfter[.cursor] == shellBefore[.cursor])
            store.updateSettings { $0.monitoringEnabled = false }
            try! await Task.sleep(for: .milliseconds(100))
            click(anchors(shellHost)[0], in: shellPanel)
            try! await Task.sleep(for: .milliseconds(100))
            let offReads = await reads.snapshot()
            precondition(offReads == shellAfter && store.refreshing.isEmpty, "Disabled native clicks do not discover credentials, request data or spin")
            shell.updatePointerRouting()
            capture("shell-strip", shellHost)
            shell.showSettings()
            let shellSettings = app.windows.first { $0.title == L10n.tr("usage.settings.window_title") }!
            precondition(shellSettings.isVisible, "Settings action must open the native window")
            weak var closedSettingsContent = shellSettings.contentView
            shellSettings.performClose(nil)
            try! await Task.sleep(for: .milliseconds(200))
            precondition(!shellSettings.isVisible && shellSettings.contentView == nil && closedSettingsContent == nil,
                         "Closed settings must release their observing SwiftUI graph")
            store.updateSettings { $0.opacity = 0.8 }
            shell.showSettings()
            precondition(shellSettings.isVisible && shellSettings.contentView != nil, "Reopening settings rebuilds from current values")
            shell.toggleVisibility()
            try! await Task.sleep(for: .milliseconds(100))
            precondition(!shellPanel.isVisible, "Hide action must update the real panel")
            shell.toggleVisibility()
            try! await Task.sleep(for: .milliseconds(100))
            await shell.stop()
            precondition(!shellPanel.isVisible && !shellSettings.isVisible && shellSettings.contentView == nil, "Shutdown must hide both windows and release settings content")
            shell.start()
            try! await Task.sleep(for: .milliseconds(100))
            precondition(shellPanel.isVisible, "Rejected quit must restore the same controller")
            shell.showSettings()
            precondition(shellSettings.isVisible, "Settings remain usable after restart")
            await shell.stop()
            for edge in UsageBarEdge.allCases {
                let screen = NSRect(x: -1000, y: -400, width: 800, height: 600)
                for position in [-1.0, 0, 0.5, 1, 2, Double.nan] {
                    let frame = UsageBarController.frame(contentSize: NSSize(width: 1200, height: 80), screenFrame: screen, edge: edge, horizontalPosition: position)
                    precondition(screen.contains(frame), "Strip must fit negative-origin/narrow displays")
                    precondition(abs(frame.width / frame.height - 15) < 0.001, "Fit preserves aspect ratio")
                }
            }
            for edge in UsageBarEdge.allCases {
                for scale in [0.6, 1.0, 1.8] {
                    var settings = store.settings
                    settings.edge = edge; settings.scale = scale
                    let width = UsageNotchLayout.shapeLength(count: settings.providers.count) * scale
                    let height = UsageNotchLayout.bodyDepth * scale
                    let emptyCorner = CGPoint(x: 2 * scale, y: edge == .top ? height - scale : scale)
                    let center = CGPoint(x: width / 2, y: height / 2)
                    let orb = CGPoint(x: width, y: edge == .top ? UsageNotchLayout.curlRadius * scale : height - UsageNotchLayout.curlRadius * scale)
                    precondition(!UsageBarView.containsInteraction(at: emptyCorner, settings: settings))
                    precondition(UsageBarView.containsInteraction(at: center, settings: settings))
                    precondition(UsageBarView.containsInteraction(at: orb, settings: settings))
                    precondition(!UsageBarView.containsInteraction(at: CGPoint(x: width + 100, y: height), settings: settings))
                }
            }
            print("PASS: actual shell geometry, transparent hit testing/pointer routing, nonactivating startup, settings, show/hide, stop/restart with injected fixture store")
            try! FileManager.default.removeItem(at: directory)
            print("PASS: isolated native fixture rendering; no production directories, accounts, keychain or network read")
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        app.run()
    }
}

#endif
