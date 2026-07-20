@testable import ChatUI
import Localization
import XCTest

final class SettingsSearchMatcherTests: XCTestCase {
    func testConcreteSectionsMapToTheirOwningScopes() {
        XCTAssertEqual(SettingsSectionID.allCases.count, 11)
        XCTAssertEqual(SettingsSectionID.petManagement.scope, .pet)
        XCTAssertEqual(SettingsSectionID.spritePacks.scope, .sprite)
        XCTAssertEqual(SettingsSectionID.chatAppearance.scope, .sprite)
        XCTAssertEqual(SettingsSectionID.desktopAwareness.scope, .awareness)
        XCTAssertEqual(SettingsSectionID.weatherAwareness.scope, .awareness)
        XCTAssertEqual(SettingsSectionID.sound.scope, .awareness)
        XCTAssertEqual(SettingsSectionID.aiConfiguration.scope, .ai)
        XCTAssertEqual(SettingsSectionID.remoteMemory.scope, .ai)
        XCTAssertEqual(SettingsSectionID.notifications.scope, .notifications)
        XCTAssertEqual(SettingsSectionID.plugins.scope, .plugins)
        XCTAssertEqual(SettingsSectionID.capabilities.scope, .capability)
    }

    func testEmptyQueryUsesSelectedScopeAndAllScopeShowsEverything() {
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(selectedScope: .pet, query: "  \n "),
            [.petManagement]
        )
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(selectedScope: .all, query: ""),
            Set(SettingsSectionID.allCases)
        )
    }

    func testStaticTermsSearchAcrossScopesWithoutShowingUnrelatedSections() {
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(selectedScope: .pet, query: "Webhook"),
            [.notifications]
        )
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(selectedScope: .plugins, query: "天气"),
            [.weatherAwareness]
        )
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(selectedScope: .pet, query: "远程记忆"),
            [.remoteMemory]
        )
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(selectedScope: .ai, query: "透明度"),
            [.chatAppearance]
        )
        XCTAssertTrue(
            SettingsSearchMatcher.visibleSections(selectedScope: .all, query: "definitely-no-such-setting").isEmpty
        )
    }

    func testVisibleControlLabelsLocateTheirConcreteSections() {
        let expectations: [(String, Set<SettingsSectionID>)] = [
            ("测试连接", [.aiConfiguration]),
            ("导出", [.spritePacks]),
            ("服务地址", [.remoteMemory]),
            ("分类", [.desktopAwareness]),
            ("间隔", [.desktopAwareness, .weatherAwareness]),
            ("在 Finder 中显示", [.plugins]),
        ]

        for (query, expectedSections) in expectations {
            XCTAssertEqual(
                SettingsSearchMatcher.visibleSections(selectedScope: .pet, query: query),
                expectedSections,
                "query: \(query)"
            )
        }
    }

    func testSearchableTermsFollowRuntimeLocaleForPetAndSpriteLabels() {
        let originalLocale = L10n.locale
        defer { L10n.locale = originalLocale }

        L10n.locale = "en"
        let englishPetName = L10n.settingsPetManagementName
        let englishPackDelete = L10n.settingsSpritePacksDelete
        XCTAssertTrue(SettingsSectionID.petManagement.searchableTerms.contains(englishPetName))
        XCTAssertTrue(SettingsSectionID.petManagement.searchableTerms.contains(L10n.settingsPetManagementSize))
        XCTAssertTrue(SettingsSectionID.petManagement.searchableTerms.contains(L10n.settingsPetManagementGender))
        XCTAssertTrue(SettingsSectionID.petManagement.searchableTerms.contains(L10n.settingsPetManagementAge))
        XCTAssertTrue(SettingsSectionID.spritePacks.searchableTerms.contains(englishPackDelete))
        XCTAssertTrue(SettingsSectionID.spritePacks.searchableTerms.contains(L10n.settingsSpritePacksStatesCount))
        XCTAssertTrue(SettingsSectionID.spritePacks.searchableTerms.contains(L10n.settingsSpritePacksFramesCount))
        XCTAssertTrue(SettingsSectionID.spritePacks.searchableTerms.contains(L10n.settingsSpritePacksBuiltIn))

        L10n.locale = "zh-Hans"
        XCTAssertNotEqual(englishPetName, L10n.settingsPetManagementName)
        XCTAssertNotEqual(englishPackDelete, L10n.settingsSpritePacksDelete)
        XCTAssertTrue(SettingsSectionID.petManagement.searchableTerms.contains(L10n.settingsPetManagementName))
        XCTAssertTrue(SettingsSectionID.spritePacks.searchableTerms.contains(L10n.settingsSpritePacksDelete))
    }

    func testParentTermReturnsEveryDynamicRowInOriginalOrder() {
        let rows = ["alpha", "beta", "gamma"]

        XCTAssertEqual(
            SettingsSearchMatcher.matchingIndices(
                in: rows,
                query: "宠物管理",
                parent: .petManagement,
                searchableFields: { [$0] }
            ),
            [0, 1, 2]
        )
    }

    func testDynamicRowsMatchPetsSpritePacksDesktopRulesPluginsAndCapabilities() {
        let examples: [(SettingsSectionID, [[String]], String, [Int])] = [
            (.petManagement, [["团子", "活泼"], ["豆包", "安静"]], "豆包", [1]),
            (.spritePacks, [["经典猫", "classic"], ["像素柴犬", "pixel-dog"]], "pixel-dog", [1]),
            (.desktopAwareness, [["开发", "com.apple.dt.Xcode"], ["音乐", "com.spotify.client"]], "spotify", [1]),
            (.plugins, [["Git Celebrate", "git-celebrate"], ["番茄钟", "pomodoro"]], "pomodoro", [1]),
            (.capabilities, [["屏幕感知", "读取屏幕"], ["日历访问", "读取日程"]], "日历", [1]),
        ]

        for (section, fields, query, expectedIndices) in examples {
            let indices = SettingsSearchMatcher.matchingIndices(
                in: fields,
                query: query,
                parent: section,
                searchableFields: { $0 }
            )
            XCTAssertEqual(indices, expectedIndices, "section: \(section)")
            XCTAssertEqual(
                SettingsSearchMatcher.visibleSections(
                    selectedScope: .ai,
                    query: query,
                    dynamicMatches: indices.isEmpty ? [] : [section]
                ),
                [section]
            )
        }
    }

    func testEditingPetIsPreservedDuringSearchButCannotBypassEmptyQueryScope() {
        struct Pet {
            let name: String
            let isEditing: Bool
        }

        let pets = [
            Pet(name: "团子", isEditing: true),
            Pet(name: "豆包", isEditing: false),
        ]
        let indices = SettingsSearchMatcher.matchingIndices(
            in: pets,
            query: "豆包",
            parent: .petManagement,
            searchableFields: { [$0.name] },
            preserve: \Pet.isEditing
        )

        XCTAssertEqual(indices, [0, 1])
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(
                selectedScope: .ai,
                query: "豆包",
                dynamicMatches: [.petManagement]
            ),
            [.petManagement]
        )
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(
                selectedScope: .ai,
                query: "",
                dynamicMatches: [.petManagement]
            ),
            [.aiConfiguration, .remoteMemory]
        )

        let preserveOnlyIndices = SettingsSearchMatcher.matchingIndices(
            in: pets,
            query: "Webhook",
            parent: .petManagement,
            searchableFields: { [$0.name] },
            preserve: \Pet.isEditing
        )
        XCTAssertEqual(preserveOnlyIndices, [0])
        XCTAssertEqual(
            SettingsSearchMatcher.visibleSections(
                selectedScope: .pet,
                query: "Webhook",
                dynamicMatches: [.petManagement]
            ),
            [.petManagement, .notifications]
        )
    }
}
