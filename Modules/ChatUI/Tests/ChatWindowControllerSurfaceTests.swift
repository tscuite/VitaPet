import AppKit
@testable import ChatUI
import XCTest

@MainActor
final class ChatWindowControllerSurfaceTests: XCTestCase {
    func testRepeatedChatPresentationReusesHostAndRefreshesProvider() throws {
        var availablePetsLoadCount = 0
        let controller = makeController()
        defer {
            controller.close()
        }
        controller.configureChatConversations(
            listAvailablePets: {
                availablePetsLoadCount += 1
                return []
            },
            onDeleteConversation: { _ in }
        )
        let container = try XCTUnwrap(controller.window?.contentView)

        controller.showChat()
        let firstHost = try activeContent(in: container)
        controller.showChat()
        let secondHost = try activeContent(in: container)

        XCTAssertTrue(firstHost === secondHost)
        XCTAssertEqual(availablePetsLoadCount, 2)
    }

    func testSettingsPresentationReusesCleanHostWithoutReloadingProvider() throws {
        var settingsLoadCount = 0
        let controller = makeController()
        defer {
            controller.close()
        }
        configureSpritePackProvider(on: controller) {
            settingsLoadCount += 1
            return []
        }
        let container = try XCTUnwrap(controller.window?.contentView)

        controller.showSettings()
        let firstHost = try activeContent(in: container)
        controller.showChat()
        controller.showSettings()
        let secondHost = try activeContent(in: container)

        XCTAssertTrue(firstHost === secondHost)
        XCTAssertEqual(settingsLoadCount, 1)
    }

    func testConfigurationInvalidatesSettingsContentWithoutReplacingHost() throws {
        var settingsLoadCount = 0
        let controller = makeController()
        defer {
            controller.close()
        }
        let loadItems: @MainActor () -> [SpritePackDisplayItem] = {
            settingsLoadCount += 1
            return []
        }
        configureSpritePackProvider(on: controller, loadItems: loadItems)
        let container = try XCTUnwrap(controller.window?.contentView)
        controller.showSettings()
        let firstHost = try activeContent(in: container)

        configureSpritePackProvider(on: controller, loadItems: loadItems)
        controller.showSettings()
        let refreshedHost = try activeContent(in: container)

        XCTAssertTrue(firstHost === refreshedHost)
        XCTAssertEqual(settingsLoadCount, 2)
    }

    func testTransientPagesCreateNewHostsAfterLeaving() throws {
        let controller = makeController()
        defer {
            controller.close()
        }
        let container = try XCTUnwrap(controller.window?.contentView)

        controller.showActivityLog()
        let firstActivityHost = try activeContent(in: container)
        controller.showChat()
        XCTAssertNil(firstActivityHost.superview)
        controller.showActivityLog()
        let secondActivityHost = try activeContent(in: container)
        XCTAssertFalse(firstActivityHost === secondActivityHost)

        controller.showStatistics()
        let firstStatisticsHost = try activeContent(in: container)
        controller.showChat()
        XCTAssertNil(firstStatisticsHost.superview)
        controller.showStatistics()
        let secondStatisticsHost = try activeContent(in: container)
        XCTAssertFalse(firstStatisticsHost === secondStatisticsHost)
    }

    func testWindowKeepsContainerWhileActiveChildIsRemovedAndAdded() throws {
        let controller = makeController()
        defer {
            controller.close()
        }
        let container = try XCTUnwrap(controller.window?.contentView)

        controller.showChat()
        let chatHost = try activeContent(in: container)
        XCTAssertTrue(controller.window?.contentView === container)
        XCTAssertTrue(chatHost.superview === container)
        XCTAssertEqual(chatHost.frame, container.bounds)
        XCTAssertTrue(chatHost.autoresizingMask.contains(.width))
        XCTAssertTrue(chatHost.autoresizingMask.contains(.height))

        controller.showSettings()
        let settingsHost = try activeContent(in: container)
        XCTAssertTrue(controller.window?.contentView === container)
        XCTAssertNil(chatHost.superview)
        XCTAssertTrue(settingsHost.superview === container)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertEqual(settingsHost.frame, container.bounds)
        XCTAssertTrue(settingsHost.autoresizingMask.contains(.width))
        XCTAssertTrue(settingsHost.autoresizingMask.contains(.height))

        controller.showChat()
        XCTAssertTrue(controller.window?.contentView === container)
        XCTAssertNil(settingsHost.superview)
        XCTAssertTrue(chatHost.superview === container)
        XCTAssertEqual(container.subviews.count, 1)
    }

    func testToolbarSelectionTracksPresentedSurface() throws {
        let controller = makeController()
        defer {
            controller.close()
        }

        XCTAssertNotNil(controller.window?.toolbar)
        controller.showChat()
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "vitapet.chat")
        controller.showSettings()
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "vitapet.settings")
        controller.showActivityLog()
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "vitapet.activity")
        controller.showStatistics()
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "vitapet.statistics")
        controller.showChat()
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "vitapet.chat")
    }

    func testCompanionHomeIsWiredIntoToolbarAndRefreshesOnPresentation() throws {
        let controller = makeController()
        defer { controller.close() }
        var homeCount = 0
        controller.configureCompanionHome { petID in
            homeCount += 1
            return CompanionHomeView(
                selectedPetID: petID,
                loadPets: { [] },
                onCare: { _, _ in "OK" },
                onChat: { _ in },
                focusState: { CompanionFocusState(status: "Idle", isIdle: true, isPaused: false, remaining: 0, duration: 1500) },
                onToggleFocus: {},
                onResetFocus: {},
                availableGames: { [] },
                onStartGame: { _ in }
            )
        }
        let container = try XCTUnwrap(controller.window?.contentView)
        controller.showCompanionHome()
        let home = try activeContent(in: container)
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "vitapet.home")
        XCTAssertEqual(homeCount, 1)
        controller.showChat()
        XCTAssertNil(home.superview)
        controller.showCompanionHome(forPetId: UUID())
        XCTAssertEqual(homeCount, 2)
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "vitapet.home")
        XCTAssertTrue(controller.window?.contentView === container)
    }

    func testOffscreenWindowIsRecenteredWhenPresented() throws {
        let controller = makeController()
        defer {
            controller.close()
        }
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))

        controller.showChat()

        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        XCTAssertTrue(isVisible)
        XCTAssertGreaterThan(window.frame.minX, -100)
    }
}

@MainActor
private func makeController() -> ChatWindowController {
    _ = NSApplication.shared
    return ChatWindowController()
}

@MainActor
private func activeContent(in container: NSView) throws -> NSView {
    XCTAssertEqual(container.subviews.count, 1)
    return try XCTUnwrap(container.subviews.first)
}

@MainActor
private func configureSpritePackProvider(
    on controller: ChatWindowController,
    loadItems: @escaping @MainActor () -> [SpritePackDisplayItem]
) {
    controller.configureSpritePackManagement(
        loadSpritePackItems: loadItems,
        selectedSpritePackID: { "default" },
        onSelectSpritePack: { _ in },
        onImportPack: { nil },
        onExportPack: { _ in nil },
        onDeletePack: { _ in nil },
        onRevealInFinder: { _ in },
        onCreateTemplate: { nil }
    )
}
