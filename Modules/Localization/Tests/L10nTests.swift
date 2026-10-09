import Foundation
import XCTest
@testable import Localization

final class L10nTests: XCTestCase {
    private var originalLocale: String = L10n.locale

    override func setUp() {
        super.setUp()
        originalLocale = L10n.locale
    }

    override func tearDown() {
        L10n.locale = originalLocale
        super.tearDown()
    }

    func testStringLookupUsesCurrentLocale() {
        L10n.locale = "zh-Hans"
        XCTAssertEqual(L10n.menuChat, "聊天")

        L10n.locale = "en"
        XCTAssertEqual(L10n.menuChat, "Chat")
    }

    func testMissingKeyFallsBackToKey() {
        L10n.locale = "en"
        XCTAssertEqual(L10n.tr("missing.key"), "missing.key")
    }

    func testArrayLookupReturnsLocalizedStrings() {
        L10n.locale = "zh-Hans"
        XCTAssertEqual(L10n.bubbleTexts.first, "嗨！")

        L10n.locale = "en"
        XCTAssertEqual(L10n.bubbleTexts.first, "Hi!")
    }

    func testMissingArrayFallsBackToKeyArray() {
        L10n.locale = "en"
        XCTAssertEqual(L10n.trs("missing.array"), ["missing.array"])
    }

    func testUnsupportedLocaleFallsBackToDefaultBundle() {
        L10n.locale = "fr"
        XCTAssertEqual(L10n.menuSettings, "设置")
    }

    func testStatusBarAndChatExperienceStringsResolve() {
        L10n.locale = "zh-Hans"
        XCTAssertEqual(L10n.menuStatistics, "数据统计")
        XCTAssertEqual(L10n.menuMiniGames, "小游戏")
        XCTAssertEqual(L10n.menuPomodoro, "番茄钟")
        XCTAssertEqual(L10n.settingsTitle, "设置")
        XCTAssertEqual(L10n.chatEmptyStart, "开始一段对话")
        XCTAssertEqual(L10n.menuPomodoroPaused("12:00"), "已暂停 · 12:00")
        XCTAssertEqual(L10n.statusMoodHappy(72), "😊 心情很好 (72)")

        L10n.locale = "en"
        XCTAssertEqual(L10n.menuStatistics, "Statistics")
        XCTAssertEqual(L10n.settingsTitle, "Settings")
        XCTAssertEqual(L10n.chatOpenSettings, "Open Settings")
    }

    func testCompanionHomeStringsResolveInBothLanguages() {
        let keys = ["home.title", "home.daily", "home.achievements", "home.journal", "home.load_error"]
            + ["feed", "play", "pat", "rest"].flatMap {
                ["home.action.\($0)", "home.action.\($0).hint", "home.response.\($0)", "home.entry.\($0)"]
            }
            + ["firstCare", "dailyRoutine", "threeDays", "bestFriends", "devoted"].flatMap {
                ["home.badge.\($0)", "home.badge.\($0).hint"]
            }
        for locale in ["zh-Hans", "en"] {
            L10n.locale = locale
            for key in keys { XCTAssertNotEqual(L10n.tr(key), key) }
        }
    }

    func testTableURLFindsCopiedResourcesInXcodeStyleBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VitaPetL10n-\(UUID().uuidString).bundle", isDirectory: true)
        let nested = root.appendingPathComponent("Contents/Resources/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(#"{"menu.chat":"聊天"}"#.utf8).write(to: nested.appendingPathComponent("zh-Hans.json"))
        try Self.writeBundlePlist(to: root.appendingPathComponent("Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertNil(bundle.url(forResource: "zh-Hans", withExtension: "json"))

        let url = try XCTUnwrap(LocalizationResourceLookup.tableURL(for: "zh-Hans", in: bundle))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        XCTAssertEqual(object["menu.chat"], "聊天")
    }

    func testTableURLFindsCopiedResourcesInSwiftPMStyleBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VitaPetL10n-\(UUID().uuidString).bundle", isDirectory: true)
        let nested = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(#"{"menu.chat":"Chat"}"#.utf8).write(to: nested.appendingPathComponent("en.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try XCTUnwrap(Bundle(url: root))
        let url = try XCTUnwrap(LocalizationResourceLookup.tableURL(for: "en", in: bundle))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        XCTAssertEqual(object["menu.chat"], "Chat")
    }

    private static func writeBundlePlist(to url: URL) throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>vitapet.Localization.tests</string>
          <key>CFBundlePackageType</key>
          <string>BNDL</string>
        </dict>
        </plist>
        """
        try Data(plist.utf8).write(to: url)
    }
}
