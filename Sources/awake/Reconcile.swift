import Foundation

/// Everything awake reads before deciding, gathered without changing anything.
struct Snapshot: Sendable {
    var inputs: Inputs
    var decision: Decision
    /// The kernel's SleepDisabled flag right now: on means lid sleep is off.
    var flag: Bool
    var lidClosed: Bool
    var status: Status?
    /// The battery energy mode awake saved before switching to Low Power.
    var savedEnergy: Int?

    static func take() -> Snapshot {
        let status = Store.status()
        let root = System.rootDomain()
        let release = Store.release()
        let inputs = Inputs(now: Date().timeIntervalSince1970, boot: System.bootSession(), mode: Store.mode(),
                            leases: leaseEntries(), battery: System.battery(), thermal: System.thermal(),
                            guards: status?.guards ?? Guards(), releaseUntil: release?.until,
                            releaseBoot: release?.boot, keepDisplayOn: Store.keepDisplayOn())
        return Snapshot(inputs: inputs, decision: Policy.decide(inputs), flag: root.sleepDisabled,
                        lidClosed: root.lidClosed, status: status, savedEnergy: Store.savedEnergy())
    }

    private static func leaseEntries() -> [LeaseEntry] {
        Store.leases().compactMap { name, lease in
            guard let kind = LeaseKind(fileName: name) else { return nil }
            return LeaseEntry(name: name, kind: kind, lease: lease, pidAlive: alive(kind, lease))
        }
    }

    /// A pid can be reused, so an agent's must still belong to claude or codex, and a command's must
    /// still be the `awake run` process that wrote the lease.
    private static func alive(_ kind: LeaseKind, _ lease: Lease) -> Bool {
        guard let pid = lease.pid, pid > 0 else { return true }
        guard let process = Proc.info(pid) else { return false }
        switch kind {
        case .agent: return process.name == lease.agent
        case .run: return abs(process.started - lease.started) < 2
        case .timer: return true
        }
    }
}

/// `awake reconcile`: decides from the current state and applies it. Idempotent, so hooks, the
/// menu, the command line and launchd's 30-second run can all call it.
enum Reconcile {
    @discardableResult
    static func run(locked: Bool = false, sleepAfterRelease: Bool = true) -> Status? {
        guard locked else {
            return Store.withLock { apply(sleepAfterRelease: sleepAfterRelease) }
        }
        return apply(sleepAfterRelease: sleepAfterRelease)
    }

    private static func apply(sleepAfterRelease: Bool) -> Status {
        // Hooks only queue their events, so every lease changes here, under the lock.
        for (file, event) in Store.queuedEvents() {
            let old = Store.lease(event.lease)
            let lease = Lease.applying(event, to: old)
            if lease != old { Store.setLease(event.lease, lease) }
            Store.removeEvent(file)
        }

        let s = Snapshot.take()
        let d = s.decision, now = s.inputs.now, previous = s.status
        var flag = s.flag
        var error: String? = nil
        var flagFailedAt: Double? = nil, energyFailedAt: Double? = nil
        var loggedAt = previous?.loggedAt
        var released = false
        var pendingSleep = previous?.pendingSleep
        if d.awake {
            pendingSleep = nil
        } else if !sleepAfterRelease && pendingSleep != nil {
            pendingSleep = false
        }
        // pmset can finish before powerd updates the kernel flag. Complete that release on a
        // later read, keeping uninstall/logout's suppression across retries too.
        if !flag, !d.awake, let intent = pendingSleep {
            if previous?.flag == true {
                Store.log("lid sleep on   \(reason(d, s, elsewhere: false))  (\(conditions(s)))")
            }
            released = intent
            pendingSleep = nil
        }
        // A helper that isn't set up fails the same way every time: retry once a minute, not on every hook.
        func waiting(_ failedAt: Double?) -> Bool { failedAt.map { now - $0 < 60 } ?? false }

        if d.awake != flag {
            if !d.awake && pendingSleep == nil { pendingSleep = sleepAfterRelease }
            if waiting(previous?.flagFailedAt) {
                error = previous?.error
                flagFailedAt = previous?.flagFailedAt
            } else {
                if let problem = System.setSleepDisabled(d.awake) {
                    error = problem
                    flagFailedAt = now
                }
                let after = System.rootDomain().sleepDisabled
                if after != flag {
                    let elsewhere = previous.map { $0.flag != flag } ?? false
                    let state = Format.lidSleep(after).lowercased().padding(toLength: 3, withPad: " ", startingAt: 0)
                    Store.log("lid sleep \(state)  \(reason(d, s, elsewhere: elsewhere))  (\(conditions(s)))")
                    released = flag && !after && pendingSleep == true
                    if !after { pendingSleep = nil }
                    if after { loggedAt = now }
                    flag = after
                }
            }
        }

        // Low Power while the lid is closed on battery and the flag keeps the Mac running.
        let onBattery = s.inputs.battery.map { !$0.external } ?? false
        let wantLow = s.lidClosed && onBattery && flag
        if Policy.energyNeedsCurrent(wantLow: wantLow, saved: s.savedEnergy) {
            if waiting(previous?.energyFailedAt) {
                error = error ?? previous?.error
                energyFailedAt = previous?.energyFailedAt
            } else {
                let current = System.batteryEnergyMode()
                switch Policy.energyPlan(wantLow: wantLow, saved: s.savedEnergy, current: current) {
                case .lower(let saved):
                    Store.saveEnergy(saved)
                    if let problem = System.setBatteryEnergyMode(Policy.lowPower) {
                        // The helper may have applied the change before its reply was lost. Keep
                        // the original mode unless a fresh read proves it is still unchanged.
                        if System.batteryEnergyMode() == saved { Store.forgetEnergy() }
                        error = problem
                        energyFailedAt = now
                    } else {
                        Store.log("Low Power on, was \(Format.energyMode(saved))  (lid closed on battery)")
                    }
                case .restore(let saved):
                    if let problem = System.setBatteryEnergyMode(saved) {
                        error = problem
                        energyFailedAt = now
                    } else {
                        Store.forgetEnergy()
                        let why = !s.lidClosed ? "lid open" : !onBattery ? "plugged in" : "lid sleep on"
                        Store.log("Low Power off, \(Format.energyMode(saved)) again  (\(why))")
                    }
                case .keep:
                    Store.forgetEnergy()
                    Store.log("\(Format.energyMode(current ?? 0)) kept, the energy mode was changed outside Awake")
                case .none:
                    break
                }
            }
        }
        if let error, error != previous?.error { Store.log("error: \(error)") }

        // macOS decides about sleep when the lid closes, so releasing the flag with the lid already
        // closed leaves the Mac running. Put it to sleep instead.
        if released && !d.awake && !flag && s.lidClosed && sleepAfterRelease {
            Store.log("going to sleep  (lid closed)")
            System.sleepNow()
        }

        for name in d.expired { Store.removeLease(name) }
        if s.inputs.releaseUntil != nil && !d.released { Store.clearRelease() }

        if flag && s.lidClosed {
            if now - (loggedAt ?? 0) >= 120 {
                Store.log("still running  (\(conditions(s)))")
                loggedAt = now
            }
        } else {
            loggedAt = nil
        }

        let status = Status(awake: d.awake, flag: flag, error: error, guards: d.guards, pendingSleep: pendingSleep, flagFailedAt: flagFailedAt,
                            energyFailedAt: energyFailedAt, loggedAt: loggedAt)
        if status != previous { Store.setStatus(status) }
        return status
    }

    private static func reason(_ d: Decision, _ s: Snapshot, elsewhere: Bool) -> String {
        let text: String
        if d.awake {
            text = d.holds.map { Format.hold($0, now: s.inputs.now) }.joined(separator: ", ")
        } else if d.released {
            text = "sleep requested"
        } else if let pause = d.pause {
            text = Format.paused(pause)
        } else {
            text = d.mode == .off ? "Awake is off" : "nothing running"
        }
        return elsewhere ? "\(text), after \(Format.changedOutside(flag: s.flag))" : text
    }

    /// "lid closed, 80 %, on battery, 29.8 °C, raw 4612/6008 mAh, -9.8 W", plus the thermal state when
    /// it isn't normal.
    private static func conditions(_ s: Snapshot) -> String {
        var parts = [s.lidClosed ? "lid closed" : "lid open"]
        if let b = s.inputs.battery {
            parts.append(Format.battery(b))
            if let raw = Format.batteryRaw(b) { parts.append(raw) }
        }
        if s.inputs.thermal != .nominal { parts.append(Format.thermalState(s.inputs.thermal)) }
        return parts.joined(separator: ", ")
    }
}
