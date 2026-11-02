import Foundation
import Darwin
#if SHUTTLE_MENU_CHECKS
import AppKit
import ChatUI
import Localization
#endif

private let actionNames = ["k9s", "obsidian", "mitmproxy", "proxy_on", "proxy_off", "ae_restart", "ae_stop", "list_network"]

#if SHUTTLE_MENU_CHECKS
@MainActor private final class MenuFixtureState {
    var canAddPet = false
    var pets: [(id: UUID, name: String)] = []
    var usageCanRefresh = true
    var openedConfigurations: [URL] = []
    var editorShouldFail = false
}
#endif

private func fixtureScript() -> String {
    """
    #!/bin/zsh
    if [[ -n "$1" ]]; then
      print -r -- "$1" >> "${0:h}/actions"
      sleep 0.2
      [[ "$1" == "fail" ]] && exit 7
      exit 0
    fi
    echo '| sfimage=terminal.fill'
    echo '---'
    echo "k9s | bash=$SWIFTBAR_PLUGIN_PATH param1=k9s terminal=false"
    echo "Obsidian | bash=$SWIFTBAR_PLUGIN_PATH param1=obsidian terminal=false"
    echo 'mitmproxy'
    echo "-- Open mitmproxy | bash=$SWIFTBAR_PLUGIN_PATH param1=mitmproxy terminal=false"
    echo 'Proxy'
    echo "-- on Proxy | bash=$SWIFTBAR_PLUGIN_PATH param1=proxy_on terminal=false"
    echo "-- off Proxy | bash=$SWIFTBAR_PLUGIN_PATH param1=proxy_off terminal=false"
    echo 'ae platform'
    echo "-- restart | bash=$SWIFTBAR_PLUGIN_PATH param1=ae_restart terminal=false"
    echo "-- stop | bash=$SWIFTBAR_PLUGIN_PATH param1=ae_stop terminal=false"
    echo "list_network | bash=$SWIFTBAR_PLUGIN_PATH param1=list_network terminal=false"
    """
}

private func actions(in entries: [ShuttleMenuEntry]) -> [String] {
    entries.flatMap { entry in entry.action.map { [$0] } ?? actions(in: entry.children) }
}

private func expectFailure(_ expected: ShuttlePlugin.Failure, context: String = "", _ operation: () throws -> Void) {
    do {
        try operation()
        preconditionFailure("Expected \(expected): \(context)")
    } catch {
        precondition(error as? ShuttlePlugin.Failure == expected, "Unexpected error: \(error): \(context)")
    }
}

@main
struct ShuttleChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitapet-shuttle-check-\(UUID())/plugin dir with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = directory.appendingPathComponent("shuttle.1d.sh")
        try fixtureScript().write(to: url, atomically: true, encoding: .utf8)
        let output = try ShuttlePlugin.run(pluginURL: url)
        let entries = try ShuttlePlugin.parse(output, pluginURL: url)
        precondition(entries.map(\.title) == ["k9s", "Obsidian", "mitmproxy", "Proxy", "ae platform", "list_network"])
        precondition(actions(in: entries) == actionNames)
        precondition(entries[3].children.map(\.title) == ["on Proxy", "off Proxy"])
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("actions").path),
                     "Reading the menu must not invoke an action")

        for (index, invalid) in [
            "", "header only", "---\n", "---\n-- orphan", "---\nparent\n---- too deep",
            "---\n | bash=\(url.path) param1=k9s terminal=false",
            "---\nk9s | bash=/other/plugin.sh param1=k9s terminal=false",
            "---\nk9s | bash=\(url.path) param1=k9s terminal=true",
            "---\nk9s | bash=\(url.path) param1=k9s param2=x terminal=false",
            "---\nk9s | bash=\(url.path) param1=k9s;touch-pwned terminal=false",
            "---\nk9s | bash=\(url.path) param1= terminal=false",
            "---\nk9s | bash=\(url.path) param1=k9s terminal=false\n-- child",
            "---\n" + String(repeating: "x", count: 257),
            "---\n" + String(repeating: "header\n", count: 257),
            String(repeating: "x", count: 65_537)
        ].enumerated() {
            expectFailure(.invalidOutput, context: "menu fixture \(index)") { _ = try ShuttlePlugin.parse(invalid, pluginURL: url) }
        }
        let separators = try ShuttlePlugin.parse("header\n---\nGroup\n-- ---\n-- status\n---\nfooter", pluginURL: url)
        precondition(separators[0].children[0].isSeparator && separators[1].isSeparator)
        let crlfEntries = try ShuttlePlugin.parse(output.replacingOccurrences(of: "\n", with: "\r\n"), pluginURL: url)
        precondition(crlfEntries == entries)
        expectFailure(.invalidOutput) { _ = try ShuttlePlugin.run(pluginURL: url, action: "k9s; touch pwned") }
        _ = try ShuttlePlugin.run(pluginURL: url, action: "k9s")
        let initialActionLog = try String(contentsOf: directory.appendingPathComponent("actions"), encoding: .utf8)
        precondition(initialActionLog == "k9s\n")
        expectFailure(.exited(7)) { _ = try ShuttlePlugin.run(pluginURL: url, action: "fail") }
        expectFailure(.missing) { _ = try ShuttlePlugin.run(pluginURL: directory.appendingPathComponent("missing.sh")) }

        let huge = directory.appendingPathComponent("huge.sh")
        try "printf '%70000s' x\n".write(to: huge, atomically: true, encoding: .utf8)
        expectFailure(.invalidOutput) { _ = try ShuttlePlugin.run(pluginURL: huge) }
        let hanging = directory.appendingPathComponent("hanging.sh")
        try "sleep 30 &\necho $! > \"${0:h}/child-pid\"\nwait\n".write(to: hanging, atomically: true, encoding: .utf8)
        let start = ProcessInfo.processInfo.systemUptime
        expectFailure(.timedOut) { _ = try ShuttlePlugin.run(pluginURL: hanging) }
        precondition(ProcessInfo.processInfo.systemUptime - start < 8, "Menu generation must be bounded")
        let childPID = Int32(try String(contentsOf: directory.appendingPathComponent("child-pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        for _ in 0..<100 where kill(childPID, 0) == 0 { Thread.sleep(forTimeInterval: 0.01) }
        precondition(kill(childPID, 0) == -1, "Timed-out menu must not leave a child running")

        // Opt-in read-only parity: never call a real plugin action from the checks.
        if CommandLine.arguments.contains("--check-local-plugin") {
            let original = ShuttlePlugin.defaultURL
            let before = try Data(contentsOf: original)
            let actual = try ShuttlePlugin.parse(ShuttlePlugin.run(pluginURL: original), pluginURL: original)
            precondition(actual == entries, "The local Shuttle menu no longer matches the supported fixture")
            let after = try Data(contentsOf: original)
            precondition(after == before)
            print("Local Shuttle menu: all 8 actions match; no real action executed")
        }
        print("Shuttle parser/process checks passed (including spaces, bounds, failure and timeout)")

        #if SHUTTLE_MENU_CHECKS
        try checkMenus(url: url, directory: directory)
        #endif
    }

    #if SHUTTLE_MENU_CHECKS
    @MainActor private static func waitFor(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            precondition(Date() < deadline, "Native menu check timed out")
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor private static func findAction(_ action: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.representedObject as? String == action { return (menu, index) }
            if let submenu = item.submenu, let match = findAction(action, in: submenu) { return match }
        }
        return nil
    }

    @MainActor private static func checkMenus(url: URL, directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        L10n.locale = "zh-Hans"
        try FileManager.default.removeItem(at: directory.appendingPathComponent("actions"))
        let state = MenuFixtureState()
        let controller = ShuttleMenuController(pluginURL: url, openConfiguration: { file in
            state.openedConfigurations.append(file)
            try await Task.sleep(for: .milliseconds(50))
            if state.editorShouldFail { throw CocoaError(.fileReadNoPermission) }
        })
        let menu = controller.menuItem.submenu!
        waitFor { menu.item(at: 0)?.title == "k9s" }
        precondition(menu.delegate === controller && !menu.autoenablesItems)
        precondition(controller.menuItem.image != nil)
        var petVisible = false
        var petSize: CGFloat = 96
        let firstPet = (id: UUID(), name: "First")
        let secondPet = (id: UUID(), name: "Second")
        state.pets = [firstPet]
        var addCalls = 0
        var removedPets: [UUID] = []
        var pomodoroStarts = 0
        var startedGames: [String] = []
        let status = StatusBarController(
            chatController: ChatWindowController(), isPetVisible: { petVisible }, togglePetVisibility: { petVisible.toggle() },
            currentPetSize: { petSize }, currentMoodLevel: { .normal }, resizePets: { petSize = $0 },
            canAddPet: { state.canAddPet }, addPet: { addCalls += 1 }, removePet: { removedPets.append($0) }, listPets: { state.pets },
            startPomodoro: { pomodoroStarts += 1 }, shuttleMenuController: controller
        )
        status.availableMiniGames = { ["Fixture game"] }
        status.onStartGame = { startedGames.append($0) }
        var usageVisible = false
        var usageRefreshCalls = 0
        var usageSettingsCalls = 0
        var usageLooks = 0
        status.configureUsageBar(
            isVisible: { usageVisible }, canRefresh: { state.usageCanRefresh }, toggle: { usageVisible.toggle() },
            refresh: { usageRefreshCalls += 1 }, settings: { usageSettingsCalls += 1 }, onLook: { usageLooks += 1 }
        )
        let statusItem = Mirror(reflecting: status).children.first(where: { $0.label == "statusItem" })!.value as! NSStatusItem
        let root = statusItem.menu!
        status.menuNeedsUpdate(root)
        let rootTitles = root.items.filter { !$0.isSeparatorItem }.map(\.title)
        precondition(rootTitles == [
            L10n.tr("home.title"), L10n.menuChat, L10n.menuShowPet,
            L10n.menuPlugins, L10n.menuPomodoro, L10n.menuMiniGames, L10n.settingsPetManagement,
            L10n.menuActivityLog, L10n.menuStatistics, L10n.menuSettings, L10n.menuQuit
        ], "Keep common actions direct and secondary controls grouped")
        precondition(root.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset) == [3, 7, 9, 13])
        let plugins = root.items.first(where: { $0.title == L10n.menuPlugins })!.submenu!
        precondition(plugins.items.map(\.title) == [L10n.tr("usage.menu.title"), "Shuttle"])
        precondition(plugins.items.last === controller.menuItem)
        let configurationItem = menu.items.first(where: { $0.title == L10n.tr("shuttle.edit_config") })!
        let beforeEdit = try Data(contentsOf: url)
        menu.performActionForItem(at: menu.items.firstIndex(where: { $0 === configurationItem })!)
        _ = NSApp.sendAction(configurationItem.action!, to: configurationItem.target, from: configurationItem)
        precondition(!configurationItem.isEnabled)
        waitFor { configurationItem.isEnabled && state.openedConfigurations.count == 1 }
        let afterEdit = try Data(contentsOf: url)
        precondition(state.openedConfigurations == [url] && afterEdit == beforeEdit)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("actions").path),
                     "Opening the configuration must not execute a command")
        precondition(!root.items.contains(where: { $0 === controller.menuItem || $0.title == L10n.tr("usage.menu.title") }))
        precondition(root.items.first?.keyEquivalent == "1")
        precondition(root.items.first(where: { $0.title == L10n.menuSettings })?.keyEquivalent == ",")
        precondition(root.items.last?.keyEquivalent == "q")
        root.performActionForItem(at: 2)
        precondition(petVisible && root.items[2].title == L10n.menuHidePet)

        let usageMenu = plugins.items.first!.submenu!
        usageMenu.performActionForItem(at: 0)
        precondition(usageVisible && usageMenu.items[0].state == .on && usageMenu.items[0].title == L10n.tr("usage.menu.hide"))
        usageMenu.performActionForItem(at: 0)
        precondition(!usageVisible && usageMenu.items[0].state == .off)
        usageMenu.performActionForItem(at: 1)
        usageMenu.performActionForItem(at: 2)
        precondition(usageRefreshCalls == 1 && usageSettingsCalls == 1)
        state.usageCanRefresh = false
        status.menuNeedsUpdate(usageMenu)
        precondition(!usageMenu.items[1].isEnabled)
        status.menuWillOpen(usageMenu)
        precondition(usageLooks == 1)

        let petMenu = root.items.first(where: { $0.title == L10n.settingsPetManagement })!.submenu!
        let addItem = petMenu.items.first(where: { $0.title == L10n.menuAddPet })!
        let removeItem = petMenu.items.first(where: { $0.title == L10n.menuRemovePet })!
        precondition(petMenu.delegate === status && !addItem.isEnabled && !removeItem.isEnabled)
        precondition(removeItem.submenu?.items.first?.title == L10n.menuKeepOnePet)
        state.canAddPet = true
        state.pets.append(secondPet)
        status.menuNeedsUpdate(petMenu)
        precondition(addItem.isEnabled && removeItem.isEnabled)
        precondition(removeItem.submenu?.items.map(\.title) == [firstPet.name, secondPet.name])
        petMenu.performActionForItem(at: 0)
        removeItem.submenu!.performActionForItem(at: 1)
        precondition(addCalls == 1 && removedPets == [secondPet.id])
        let sizeMenu = petMenu.items.first(where: { $0.title == L10n.menuPetSize })!.submenu!
        precondition(sizeMenu.items.first(where: { $0.tag == 96 })?.state == .on)
        sizeMenu.performActionForItem(at: sizeMenu.items.firstIndex(where: { $0.tag == 128 })!)
        precondition(petSize == 128 && sizeMenu.items.first(where: { $0.tag == 128 })?.state == .on)
        state.pets = [firstPet]
        state.canAddPet = false
        status.menuNeedsUpdate(root)
        precondition(!addItem.isEnabled && !removeItem.isEnabled, "Nested pet controls must update from the root menu too")
        root.items.first(where: { $0.title == L10n.menuPomodoro })!.submenu!.performActionForItem(at: 1)
        root.items.first(where: { $0.title == L10n.menuMiniGames })!.submenu!.performActionForItem(at: 0)
        precondition(pomodoroStarts == 1 && startedGames == ["Fixture game"])

        let actionLog = directory.appendingPathComponent("actions")
        for action in actionNames {
            let (parent, index) = findAction(action, in: root)!
            let sender = parent.item(at: index)!
            parent.performActionForItem(at: index)
            // A second stale sender must not start another command while Terminal is opening.
            _ = NSApp.sendAction(sender.action!, to: sender.target, from: sender)
            precondition(findAction(action, in: menu).map { $0.0.item(at: $0.1)!.isEnabled } == false)
            waitFor { findAction(action, in: menu).map { $0.0.item(at: $0.1)!.isEnabled } == true }
        }
        let invoked = try String(contentsOf: actionLog, encoding: .utf8).split(separator: "\n").map(String.init)
        precondition(invoked == actionNames, "Every native menu action must route exactly once to the script")

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            for locale in ["en", "zh-Hans"] {
                L10n.locale = locale
                controller.menuWillOpen(menu)
                let trackedItem = menu.items.first!
                waitFor { menu.items.last?.isEnabled == true }
                precondition(menu.items.first === trackedItem, "Unchanged async refresh must not replace a tracked menu item")
                precondition(menu.items.last?.title == L10n.tr("shuttle.reload"))
                precondition(configurationItem.title == L10n.tr("shuttle.edit_config"))
                precondition(menu.item(at: 0)?.title == "k9s")
            }
        }

        var errors: [String] = []
        controller.onError = { errors.append($0) }
        let failingScript = fixtureScript() + "\necho \"Failure | bash=$SWIFTBAR_PLUGIN_PATH param1=fail terminal=false\"\n"
        try failingScript.write(to: url, atomically: true, encoding: .utf8)
        menu.performActionForItem(at: menu.numberOfItems - 1)
        waitFor { findAction("fail", in: menu) != nil && menu.items.last?.isEnabled == true }
        let (failureMenu, failureIndex) = findAction("fail", in: menu)!
        failureMenu.performActionForItem(at: failureIndex)
        waitFor { !errors.isEmpty }
        precondition(errors == [String(format: L10n.tr("shuttle.error.exit"), 7)])
        precondition(menu.items.last?.isEnabled == true)

        try FileManager.default.removeItem(at: url)
        controller.reload()
        waitFor { menu.items.last?.isEnabled == true }
        precondition(menu.item(at: 0)?.title == L10n.tr("shuttle.error.missing"))
        precondition(!configurationItem.isEnabled)
        precondition(findAction("k9s", in: menu) == nil)
        try fixtureScript().replacingOccurrences(of: "echo 'Proxy'", with: "echo 'Updated Proxy'")
            .write(to: url, atomically: true, encoding: .utf8)
        controller.menuWillOpen(menu)
        waitFor { menu.items.contains(where: { $0.title == "Updated Proxy" }) && menu.items.last?.isEnabled == true }
        precondition(errors.count == 1, "Menu refreshes must not execute actions or display alerts")
        precondition(configurationItem.isEnabled)
        state.editorShouldFail = true
        menu.performActionForItem(at: menu.items.firstIndex(where: { $0 === configurationItem })!)
        waitFor { errors.count == 2 && configurationItem.isEnabled }
        precondition(errors.last == L10n.tr("shuttle.error.editor"))
        precondition(state.openedConfigurations == [url, url])
        state.editorShouldFail = false
        try FileManager.default.removeItem(at: url)
        _ = NSApp.sendAction(configurationItem.action!, to: configurationItem.target, from: configurationItem)
        precondition(errors.count == 3 && errors.last == L10n.tr("shuttle.error.missing"))
        precondition(state.openedConfigurations.count == 2, "A stale editor item must not open a missing file")
        controller.reload()
        waitFor { menu.items.last?.isEnabled == true }
        precondition(!configurationItem.isEnabled)
        let finalActionLog = try String(contentsOf: actionLog, encoding: .utf8)
        precondition(finalActionLog.split(separator: "\n").count == 9)
        withExtendedLifetime(status) {}
        print("Native menu checks passed (plugin grouping, configuration editor, usage actions, pet controls, all Shuttle actions, reload and locales)")
    }
    #endif
}
