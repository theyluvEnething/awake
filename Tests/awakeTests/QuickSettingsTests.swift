import AppKit
import Testing
@testable import awake

@MainActor struct QuickSettingsTests {
    @Test func theCupMenuDisplaysIndependentLidAndDisplayPreferences() throws {
        let app = MenuApp()
        for mode in [Mode.off, .auto, .on] {
            for displayOn in [true, false] {
                let items = app.quickSettingItems(mode: mode, keepDisplayOn: displayOn)
                #expect(items.count == 2)
                #expect(items[0].state == (mode == .off ? .off : .on))
                #expect(items[1].title == "Keep display on")
                #expect(items[1].state == (displayOn ? .on : .off))
                #expect(items[1].target === app)
                let action = try #require(items[1].action)
                #expect(app.responds(to: action))
            }
        }
    }
}
