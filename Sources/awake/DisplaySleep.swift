import Foundation
import IOKit.pwr_mgt

/// The menu app owns this assertion; short-lived hooks and reconciles never keep the display on.
@MainActor
final class DisplaySleep {
    nonisolated static let name = "Awake: keep display on"

    /// Whether a process, by default any, holds Awake's display assertion. `awake status` reports this
    /// rather than the preference, which does nothing while the menu isn't running.
    nonisolated static func held(by pid: pid_t? = nil) -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return all.contains { owner, assertions in
            (pid.map { owner.int32Value == $0 } ?? true) && assertions.contains {
                $0[kIOPMAssertionNameKey] as? String == name
                    && $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertPreventUserIdleDisplaySleep
            }
        }
    }

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
                                                        Self.name as CFString,
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
