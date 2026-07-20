@testable import ChatUI
import XCTest

final class SettingsScopeTests: XCTestCase {
    func testInitialScopeBuildsOneUsefulModuleInsteadOfEveryModule() {
        XCTAssertEqual(SettingsScope.initial, .pet)
        XCTAssertFalse(SettingsScope.initial.includes(.ai))
    }

    func testAllScopeStillIncludesEveryModule() {
        for scope in SettingsScope.allCases where scope != .all {
            XCTAssertTrue(SettingsScope.all.includes(scope))
        }
    }
}
