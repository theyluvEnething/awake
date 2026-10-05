import IOKit.pwr_mgt

/// The menu app owns this assertion; short-lived hooks and reconciles never keep the display on.
@MainActor
final class DisplaySleep {
    private(set) var assertion: IOPMAssertionID?
    private(set) var error: String?
    private var ended = false
    var active: Bool { assertion != nil }

    /// Once logout or quit starts, an outstanding refresh must not acquire another assertion.
    func end() {
        ended = true
        update(false)
    }

    func update(_ requested: Bool) {
        let on = requested && !ended
        guard on != active else {
            error = nil
            return
        }
        let result: IOReturn
        if on {
            var id = IOPMAssertionID(kIOPMNullAssertionID)
            result = IOPMAssertionCreateWithDescription(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                        "Awake: keep display on" as CFString,
                                                        nil, nil, nil, 0, nil, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else {
            result = IOPMAssertionRelease(assertion!)
            if result == kIOReturnSuccess { assertion = nil }
        }
        error = result == kIOReturnSuccess ? nil : on
            ? "couldn't keep the display on; turn Keep display on off and on to try again"
            : "couldn't restore display sleep; quit and reopen Awake"
    }

    deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }
}
