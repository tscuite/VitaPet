import AppKit
import Localization
import SwiftUI
import UsageMonitor

@MainActor
public struct UsageBarSettingsView: View {
    @ObservedObject private var store: UsageMonitorStore
    private let onResetPosition: () -> Void
    @State private var screens: [NSScreen] = NSScreen.screens

    public init(store: UsageMonitorStore, onResetPosition: @escaping () -> Void) {
        self.store = store
        self.onResetPosition = onResetPosition
    }

    public var body: some View {
        Form {
            if let error = store.settingsError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section {
                Toggle(L10n.tr("usage.show"), isOn: setting(\.isVisible))
                Toggle(L10n.tr("usage.monitoring"), isOn: setting(\.monitoringEnabled))
                Text(L10n.tr("usage.privacy")).font(.caption).foregroundStyle(.secondary)
            } header: { Text(L10n.tr("usage.menu")) }

            Section {
                Picker(L10n.tr("usage.edge"), selection: setting(\.edge)) {
                    Text(L10n.tr("usage.edge.top")).tag(UsageBarEdge.top)
                    Text(L10n.tr("usage.edge.bottom")).tag(UsageBarEdge.bottom)
                }
                .pickerStyle(.segmented)
                Picker(L10n.tr("usage.screen"), selection: setting(\.screenID)) {
                    Text(L10n.tr("usage.screen.automatic")).tag(nil as String?)
                    ForEach(screens, id: \.usageScreenID) { screen in
                        Text(screen.localizedName).tag(screen.usageScreenID)
                    }
                    if let selected = store.settings.screenID, !screens.contains(where: { $0.usageScreenID == selected }) {
                        Text(L10n.tr("usage.screen.disconnected")).tag(Optional(selected))
                    }
                }
                Picker(L10n.tr("usage.surface"), selection: setting(\.surfaceStyle)) {
                    ForEach(UsageBarSurfaceStyle.allCases, id: \.self) { style in
                        Text(L10n.tr("usage.surface.\(style.rawValue)")).tag(style)
                    }
                }
                Text(L10n.tr("usage.surface.\(store.settings.surfaceStyle.rawValue)_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                slider("usage.horizontal_position", value: setting(\.horizontalPosition), range: 0...1)
                slider("usage.scale", value: setting(\.scale), range: 0.6...1.8)
                slider("usage.opacity", value: setting(\.opacity), range: 0.3...1)
                Text(L10n.tr("usage.opacity_hint")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("usage.reset_position"), action: onResetPosition)
            } header: { Text(L10n.tr("usage.appearance")) }

            Section {
                Text(L10n.tr("usage.polling.original")).font(.callout)
                Text(L10n.tr("usage.polling.activity")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.tr("usage.refresh_hint")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.isRefreshing ? L10n.tr("usage.refreshing") : L10n.tr("usage.refresh")) { store.refresh() }
                        .disabled(!store.settings.monitoringEnabled || store.isRefreshing)
                }
            } header: { Text(L10n.tr("usage.polling")) }

            Section {
                Text(L10n.tr("usage.providers_hint")).font(.caption).foregroundStyle(.secondary)
                if store.settings.providers.isEmpty {
                    Label(L10n.tr("usage.empty"), systemImage: "info.circle").foregroundStyle(.secondary)
                }
                ForEach(orderedProviders) { provider in
                    UsageSourceSettings(store: store, provider: provider)
                }
            } header: { Text(L10n.tr("usage.providers")) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 480, idealHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private var orderedProviders: [UsageProviderID] {
        store.settings.providers + UsageProviderID.allCases.filter { !store.settings.providers.contains($0) }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<UsageBarSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { value in
            store.updateSettings { $0[keyPath: keyPath] = value }
        })
    }

    private func slider(_ key: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Slider(value: value, in: range, step: 0.05) { Text(L10n.tr(key)) }
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().frame(width: 46, alignment: .trailing)
        }
    }
}

private extension NSScreen {
    var usageScreenID: String? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }
}

@MainActor
private struct UsageSourceSettings: View {
    @ObservedObject var store: UsageMonitorStore
    let provider: UsageProviderID
    private var isSelected: Bool { store.settings.providers.contains(provider) }
    private var status: UsageReadingStatus {
        guard store.settings.monitoringEnabled, isSelected else { return .disabled }
        return store.readings.first { $0.provider == provider }?.status ?? .notConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(provider.displayName, isOn: Binding(get: { isSelected }, set: { enabled in
                    store.updateSettings { settings in
                        if enabled { settings.providers.append(provider) }
                        else { settings.providers.removeAll { $0 == provider } }
                    }
                }))
                Spacer()
                Text(UsagePresentation.status(status)).font(.caption).foregroundStyle(.secondary)
                if let index = store.settings.providers.firstIndex(of: provider) {
                    Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        .help(L10n.tr("usage.move_up"))
                        .accessibilityLabel("\(provider.displayName): \(L10n.tr("usage.move_up"))")
                    Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == store.settings.providers.count - 1)
                        .help(L10n.tr("usage.move_down"))
                        .accessibilityLabel("\(provider.displayName): \(L10n.tr("usage.move_down"))")
                }
            }
            DisclosureGroup(L10n.tr("usage.connection")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("usage.source.\(provider.rawValue)"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let reading = store.readings.first(where: { $0.provider == provider }), store.settings.monitoringEnabled {
                        if let detail = reading.detail {
                            Text(UsagePresentation.detail(detail)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let updated = reading.updatedAt {
                            Text("\(L10n.tr("usage.updated")) \(updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button(L10n.tr("usage.refresh")) { store.refresh(provider) }
                        .disabled(!store.settings.monitoringEnabled || !isSelected || store.isRefreshing)
                    if !store.settings.monitoringEnabled {
                        Text(L10n.tr("usage.off_hint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func move(by offset: Int) {
        store.updateSettings { settings in
            guard let index = settings.providers.firstIndex(of: provider), settings.providers.indices.contains(index + offset) else { return }
            settings.providers.swapAt(index, index + offset)
        }
    }

}
