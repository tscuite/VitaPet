import ChatUI
import XCTest

final class ChatAppearanceSettingsTests: XCTestCase {
    func testOpacityIsClampedToVisibleRange() {
        XCTAssertEqual(ChatAppearanceSettings(translucencyEnabled: true, opacity: 0.1).opacity, 0.55)
        XCTAssertEqual(ChatAppearanceSettings(translucencyEnabled: true, opacity: 1.5).opacity, 1.0)
        XCTAssertEqual(ChatAppearanceSettings(translucencyEnabled: false, opacity: .nan).opacity, 1.0)
    }

    func testDirectOpacityControlEnablesTranslucencyBelowFullOpacity() {
        XCTAssertEqual(
            ChatAppearanceSettings.directOpacityControlValue(translucencyEnabled: false, opacity: 0.72),
            1.0
        )

        XCTAssertEqual(
            ChatAppearanceSettings.settingsFromDirectOpacityControl(0.72),
            ChatAppearanceSettings(translucencyEnabled: true, opacity: 0.72)
        )
        XCTAssertEqual(
            ChatAppearanceSettings.settingsFromDirectOpacityControl(1.0),
            ChatAppearanceSettings(translucencyEnabled: false, opacity: 1.0)
        )
    }
}
