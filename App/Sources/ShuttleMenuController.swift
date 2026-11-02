import AppKit
import Localization

@MainActor
final class ShuttleMenuController: NSObject, NSMenuDelegate {
    let menuItem = NSMenuItem(title: "Shuttle", action: nil, keyEquivalent: "")
    private let pluginURL: URL
    private let openConfiguration: @MainActor (URL) async throws -> Void
    private let editMenuItem = NSMenuItem()
    private var isOpeningConfiguration = false
    private var entries: [ShuttleMenuEntry] = []
    private var loadError: (any Error)?
    private var isLoading = false
    private var isRunningAction = false
    var onError: (@MainActor (String) -> Void)?

    init(
        pluginURL: URL = ShuttlePlugin.defaultURL,
        openConfiguration: @escaping @MainActor (URL) async throws -> Void = ShuttleMenuController.openInTextEdit
    ) {
        self.pluginURL = pluginURL
        self.openConfiguration = openConfiguration
        super.init()
        menuItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        let menu = NSMenu(title: menuItem.title)
        menu.autoenablesItems = false
        menu.delegate = self
        menuItem.submenu = menu
        reload()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        reload()
    }

    @objc func reload() {
        guard !isLoading, !isRunningAction else { return }
        isLoading = true
        if entries.isEmpty {
            rebuildMenu()
        } else {
            menuItem.submenu?.items.last?.isEnabled = false
        }
        let url = pluginURL
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try ShuttlePlugin.parse(ShuttlePlugin.run(pluginURL: url), pluginURL: url) }
            }.value
            guard let self else { return }
            self.isLoading = false
            let previousEntries = self.entries
            switch result {
            case .success(let entries):
                self.entries = entries
                self.loadError = nil
            case .failure(let error):
                self.entries = []
                self.loadError = error
            }
            if self.entries.isEmpty || self.entries != previousEntries {
                self.rebuildMenu()
            } else {
                self.menuItem.submenu?.items.last?.isEnabled = !self.isRunningAction
            }
        }
    }

    private func rebuildMenu() {
        guard let menu = menuItem.submenu else { return }
        menu.removeAllItems()
        if entries.isEmpty {
            let title = isLoading ? L10n.tr("shuttle.loading") : failureText(loadError)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for entry in entries { menu.addItem(makeItem(entry)) }
        }
        menu.addItem(.separator())
        editMenuItem.title = L10n.tr("shuttle.edit_config")
        editMenuItem.target = self
        editMenuItem.action = #selector(editConfiguration)
        editMenuItem.isEnabled = !isOpeningConfiguration && FileManager.default.isReadableFile(atPath: pluginURL.path)
        menu.addItem(editMenuItem)
        let reloadItem = NSMenuItem(title: L10n.tr("shuttle.reload"), action: #selector(reload), keyEquivalent: "")
        reloadItem.target = self
        reloadItem.isEnabled = !isLoading && !isRunningAction
        menu.addItem(reloadItem)
    }

    private func makeItem(_ entry: ShuttleMenuEntry) -> NSMenuItem {
        if entry.isSeparator { return .separator() }
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        if !entry.children.isEmpty {
            let submenu = NSMenu(title: entry.title)
            submenu.autoenablesItems = false
            for child in entry.children { submenu.addItem(makeItem(child)) }
            item.submenu = submenu
        } else if let action = entry.action {
            item.target = self
            item.action = #selector(runAction(_:))
            item.representedObject = action
            item.isEnabled = !isRunningAction
        } else {
            item.isEnabled = false
        }
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard !isRunningAction, let action = sender.representedObject as? String,
              entries.contains(where: { $0.action == action || $0.children.contains(where: { $0.action == action }) }) else {
            return
        }
        isRunningAction = true
        rebuildMenu()
        let url = pluginURL
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ShuttlePlugin.run(pluginURL: url, action: action) }
            }.value
            guard let self else { return }
            self.isRunningAction = false
            self.rebuildMenu()
            if case .failure(let error) = result {
                self.presentError(self.failureText(error))
            }
        }
    }

    @objc private func editConfiguration() {
        guard !isOpeningConfiguration else { return }
        guard FileManager.default.isReadableFile(atPath: pluginURL.path) else {
            presentError(L10n.tr("shuttle.error.missing"))
            return
        }
        isOpeningConfiguration = true
        editMenuItem.isEnabled = false
        let url = pluginURL
        let open = openConfiguration
        Task { [weak self] in
            do { try await open(url) } catch {
                self?.presentError(L10n.tr("shuttle.error.editor"))
            }
            guard let self else { return }
            self.isOpeningConfiguration = false
            self.editMenuItem.isEnabled = FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    private static func openInTextEdit(_ url: URL) async throws {
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            throw ShuttlePlugin.Failure.launchFailed
        }
        // Never use the default .sh association: configuration editing must not execute the script.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: .init()) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func presentError(_ text: String) {
        if let onError {
            onError(text)
        } else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("shuttle.error.title")
            alert.informativeText = text
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func failureText(_ error: (any Error)?) -> String {
        switch error as? ShuttlePlugin.Failure {
        case .missing: L10n.tr("shuttle.error.missing")
        case .invalidOutput: L10n.tr("shuttle.error.format")
        case .timedOut: L10n.tr("shuttle.error.timeout")
        case .exited(let status): String(format: L10n.tr("shuttle.error.exit"), status)
        default: L10n.tr("shuttle.error.run")
        }
    }
}
