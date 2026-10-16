import IOKit.pwr_mgt
import Testing
@testable import awake

@Suite(.serialized) @MainActor struct DisplaySleepTests {
    @Test func powerAndThermalChangesKeepTheSameUntimedAssertion() throws {
        let display = DisplaySleep()
        defer { display.end() }
        var inputs = Inputs(now: 100, boot: "boot", mode: ModeState(mode: .off), leases: [],
                            battery: nil, thermal: .nominal, guards: Guards(), releaseUntil: nil,
                            keepDisplayOn: true)
        display.update(Policy.decide(inputs).displayAwake)
        let id = try #require(display.assertion)
        for external in [true, false, true, false] {
            for thermal in [Thermal.nominal, .serious, .critical] {
                inputs.battery = Battery(level: 10, charging: false, external: external, temperature: 45)
                inputs.thermal = thermal
                display.update(Policy.decide(inputs).displayAwake)
                #expect(display.assertion == id)
                #expect(DisplaySleep.held(by: getpid()))
            }
        }
        inputs.keepDisplayOn = false
        display.update(Policy.decide(inputs).displayAwake)
        #expect(!display.active)
        #expect(IOPMAssertionCopyProperties(id) == nil)
    }

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

    @Test func statusSeesTheAssertionThisProcessHolds() {
        let display = DisplaySleep()
        #expect(!DisplaySleep.held(by: getpid()))
        display.update(true)
        #expect(DisplaySleep.held(by: getpid()))
        #expect(DisplaySleep.held())
        display.update(false)
        #expect(!DisplaySleep.held(by: getpid()))
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
