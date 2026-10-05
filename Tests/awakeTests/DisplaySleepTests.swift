import IOKit.pwr_mgt
import Testing
@testable import awake

@Suite(.serialized) @MainActor struct DisplaySleepTests {
    @Test func enablingTwiceKeepsOneUntimedDisplayAssertionAndDisablingReleasesIt() throws {
        let display = DisplaySleep()
        #expect(!display.active)
        display.update(true)
        let id = try #require(display.assertion)
        let properties = try #require(IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any])
        #expect(properties[kIOPMAssertionTypeKey] as? String == kIOPMAssertPreventUserIdleDisplaySleep)
        #expect(properties[kIOPMAssertionLevelKey] as? Int == kIOPMAssertionLevelOn)
        #expect((properties[kIOPMAssertionTimeoutKey] as? Double ?? 0) == 0)
        #expect(display.active)
        #expect(display.error == nil)

        display.update(true)
        #expect(display.assertion == id)
        display.update(false)
        #expect(!display.active)
        #expect(display.error == nil)
        #expect(IOPMAssertionCopyProperties(id) == nil)
        display.update(false)
        #expect(!display.active)
    }

    @Test func destroyingTheOwnerReleasesItsAssertion() throws {
        var display: DisplaySleep? = DisplaySleep()
        display?.update(true)
        let id = try #require(display?.assertion)
        #expect(IOPMAssertionCopyProperties(id) != nil)
        display = nil
        #expect(IOPMAssertionCopyProperties(id) == nil)
    }

    @Test func endingTheSessionPreventsAPendingRefreshFromRecreatingTheAssertion() throws {
        let display = DisplaySleep()
        display.update(true)
        let id = try #require(display.assertion)
        display.end()
        #expect(!display.active)
        #expect(IOPMAssertionCopyProperties(id) == nil)
        display.update(true)
        #expect(!display.active)
        #expect(display.assertion == nil)
    }
}
