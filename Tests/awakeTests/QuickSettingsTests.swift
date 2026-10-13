import AppKit
import Testing
@testable import awake

@MainActor struct QuickSettingsTests {
    @Test func cupIconsDistinguishAllThreeModesWithoutChangingTheirSize() throws {
        for render in [
            { Glyph.status(mode: $0, warning: false) },
            { Glyph.status(mode: $0, warning: true) },
            { Glyph.menu(mode: $0) },
        ] as [(Mode) -> NSImage] {
            let icons = [Mode.off, .auto, .on].map(render)
            let pixels = try icons.map { try #require($0.tiffRepresentation) }
            #expect(Set(pixels).count == 3)
            for icon in icons {
                #expect(icon.isTemplate)
                #expect(icon.size == icons[0].size)
            }
        }
        for mode in [Mode.off, .auto, .on] {
            #expect(Glyph.status(mode: mode, warning: false).tiffRepresentation
                != Glyph.status(mode: mode, warning: true).tiffRepresentation)
        }
    }

    @Test func maintenanceActionsAreOnlyAvailableThroughSettings() throws {
        let app = MenuApp()
        let items = app.menuItems(mode: .auto, keepDisplayOn: false).filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Awake", "Stay awake indefinitely", "Keep display on", "Settings…", "Quit Awake"])
        try #require(items.count == 5)
        for item in items {
            #expect(item.target === app)
            #expect(app.responds(to: try #require(item.action)))
        }
        #expect(items[3].keyEquivalent == ",")
        #expect(items[4].keyEquivalent == "q")
    }

    @Test func theCupMenuDisplaysIndependentLidAndDisplayPreferences() throws {
        let app = MenuApp()
        for mode in [Mode.off, .auto, .on] {
            for displayOn in [true, false] {
                let items = app.quickSettingItems(mode: mode, keepDisplayOn: displayOn)
                #expect(items.map(\.title) == (mode == .off
                    ? ["Awake", "Keep display on"]
                    : ["Awake", "Stay awake indefinitely", "Keep display on"]))
                #expect(items[0].state == (mode == .off ? .off : .on))
                if mode != .off {
                    #expect(items[1].state == (mode == .on ? .on : .off))
                    #expect(items[1].indentationLevel == 1)
                    #expect(items[1].isEnabled)
                    #expect(items[1].image != nil)
                    #expect(items[1].target === app)
                    #expect(app.responds(to: try #require(items[1].action)))
                }
                let display = try #require(items.last)
                #expect(display.state == (displayOn ? .on : .off))
                #expect(display.target === app)
                let action = try #require(display.action)
                #expect(app.responds(to: action))
                let closed = app.quickSettingItems(mode: mode, keepDisplayOn: displayOn, lidClosed: true)
                #expect(closed.last?.state == .off)
                #expect(closed.last?.isEnabled == false)
                #expect(closed[0].state == items[0].state)
                let reopened = app.quickSettingItems(mode: mode, keepDisplayOn: false, lidClosed: false)
                #expect(reopened.last?.state == .off)
                #expect(reopened.last?.isEnabled == true)
            }
        }
    }
}
