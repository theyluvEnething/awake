import Foundation

/// Everything awake reads before deciding, gathered without changing anything.
struct Snapshot: Sendable {
    var inputs: Inputs
    var decision: Decision
    /// The kernel's SleepDisabled switch right now.
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
                            releaseBoot: release?.boot)
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
        let s = Snapshot.take()
        let d = s.decision, now = s.inputs.now, previous = s.status
        var flag = s.flag
        var error: String? = nil
        var failedAt = previous?.failedAt
        var loggedAt = previous?.loggedAt
        var released = false
        // A missing sudo rule fails the same way every time: retry once a minute, not on every hook.
        let mayTry = failedAt.map { now - $0 >= 60 } ?? true

        if d.awake != flag {
            if mayTry {
                if let problem = System.setSleepDisabled(d.awake) {
                    error = problem
                    failedAt = now
                }
                let after = System.rootDomain().sleepDisabled
                if after != flag {
                    let elsewhere = previous.map { $0.flag != flag } ?? false
                    Store.log("\(after ? "on " : "off") \(reason(d, s, elsewhere: elsewhere))  (\(conditions(s)))")
                    released = flag && !after
                    if after { loggedAt = now }
                    flag = after
                }
            } else {
                error = previous?.error
            }
        }

        // Low Power while the lid is closed on battery and the switch keeps the Mac running.
        let onBattery = s.inputs.battery.map { !$0.external } ?? false
        let wantLow = s.lidClosed && onBattery && flag
        if mayTry && Policy.energyNeedsCurrent(wantLow: wantLow, saved: s.savedEnergy) {
            let current = System.batteryEnergyMode()
            switch Policy.energyPlan(wantLow: wantLow, saved: s.savedEnergy, current: current) {
            case .lower(let saved):
                Store.saveEnergy(saved)
                if let problem = System.setBatteryEnergyMode(Policy.lowPower) {
                    Store.forgetEnergy()
                    error = problem
                    failedAt = now
                } else {
                    Store.log("energy Low Power, was \(energyName(saved))  (lid closed on battery)")
                }
            case .restore(let saved):
                if let problem = System.setBatteryEnergyMode(saved) {
                    error = problem
                    failedAt = now
                } else {
                    Store.forgetEnergy()
                    let why = !s.lidClosed ? "lid open" : !onBattery ? "on power" : "switch off"
                    Store.log("energy \(energyName(saved)) again  (\(why))")
                }
            case .keep:
                Store.forgetEnergy()
                Store.log("energy stays \(energyName(current ?? 0)), changed outside awake")
            case .none:
                break
            }
        }
        if error == nil { failedAt = nil }
        if let error, error != previous?.error { Store.log("error: \(error)") }

        // macOS decides about sleep when the lid closes, so releasing the switch with the lid already
        // closed leaves the Mac running. Put it to sleep instead.
        if released && s.lidClosed && sleepAfterRelease {
            Store.log("sleepnow  (lid closed)")
            System.sleepNow()
        }

        for name in d.expired { Store.removeLease(name) }
        if s.inputs.releaseUntil != nil && !d.released { Store.clearRelease() }

        if flag && s.lidClosed {
            if now - (loggedAt ?? 0) >= 120 {
                Store.log("lid closed  (\(conditions(s)))")
                loggedAt = now
            }
        } else {
            loggedAt = nil
        }

        let status = Status(awake: d.awake, flag: flag, pause: d.holds.isEmpty ? nil : d.pause, error: error,
                            guards: d.guards, failedAt: failedAt, loggedAt: loggedAt)
        if status != previous { Store.setStatus(status) }
        return status
    }

    private static func reason(_ d: Decision, _ s: Snapshot, elsewhere: Bool) -> String {
        let text: String
        if d.awake {
            text = d.holds.map { Format.label($0, now: s.inputs.now) }.joined(separator: ", ")
        } else if d.released {
            text = "sleep requested"
        } else if let pause = d.pause, !d.holds.isEmpty {
            text = "paused: \(pause)"
        } else {
            text = d.mode == .off ? "mode Off" : "nothing running"
        }
        return elsewhere ? "\(text), the switch was changed outside awake" : text
    }

    static func conditions(_ s: Snapshot) -> String {
        var parts = [s.lidClosed ? "lid closed" : "lid open"]
        if let b = s.inputs.battery {
            var battery = "battery \(b.level) %"
            if let t = b.temperature { battery += String(format: " %.1f °C", t) }
            if b.charging { battery += ", charging" } else if b.external { battery += ", on power" }
            parts.append(battery)
        }
        if s.inputs.thermal != .nominal { parts.append("thermal \(s.inputs.thermal)") }
        return parts.joined(separator: ", ")
    }

    static func energyName(_ mode: Int) -> String {
        switch mode {
        case 0: "Automatic"
        case 1: "Low Power"
        case 2: "High Power"
        default: "mode \(mode)"
        }
    }
}
