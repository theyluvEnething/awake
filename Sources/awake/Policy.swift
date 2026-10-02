import Foundation

// The decision logic, kept free of I/O so it can be checked without root.

/// Off: the Mac sleeps when the lid closes. Auto: it keeps running while an agent turn runs.
/// On: it keeps running until the mode changes, the Mac restarts or the user logs out.
enum Mode: String, Codable, Sendable {
    case off, auto, on
}

/// The `mode` file. On only lasts for the boot it was turned on in, then falls back to `base`.
struct ModeState: Codable, Equatable, Sendable {
    var mode: Mode
    var base: Mode? = nil
    var boot: String? = nil
}

/// One lease file. Agent leases come from hooks; run and for leases come from the command line.
struct Lease: Codable, Equatable, Sendable {
    var agent: String? = nil
    var sessionId: String? = nil
    var pid: Int32? = nil
    var project: String? = nil
    var command: String? = nil
    var started: Double
    var lastSeen: Double? = nil
    var endedAt: Double? = nil
    var until: Double? = nil
}

enum LeaseKind: Sendable {
    case agent, run, timer

    /// The kind follows from the file name: claude-<session>, codex-<session>, run-<pid>, for-<id>.
    init?(fileName: String) {
        if fileName.hasPrefix("claude-") || fileName.hasPrefix("codex-") {
            self = .agent
        } else if fileName.hasPrefix("run-") {
            self = .run
        } else if fileName.hasPrefix("for-") {
            self = .timer
        } else {
            return nil
        }
    }
}

struct LeaseEntry: Equatable, Sendable {
    var name: String
    var kind: LeaseKind
    var lease: Lease
    /// Whether the lease's process still exists. True when the lease has no pid to check.
    var pidAlive: Bool
}

enum HookEvent: Sendable {
    /// A prompt or tool call: the session is working.
    case activity
    /// Stop, StopFailure, SessionEnd or Codex's Interrupt: the turn is over.
    case end

    init?(name: String) {
        switch name {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": self = .activity
        case "Stop", "StopFailure", "SessionEnd", "Interrupt": self = .end
        default: return nil
        }
    }
}

struct Battery: Equatable, Sendable {
    var level: Int
    /// Actually charging. A charger can be attached without charging.
    var charging: Bool
    /// A charger is attached, so the AC energy settings apply.
    var external: Bool
    /// Degrees Celsius.
    var temperature: Double?
}

enum Thermal: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
}

/// Which guards were holding the Mac asleep at the last reconcile, for their resume points.
struct Guards: Codable, Equatable, Sendable {
    var battery = false
    var heat = false
}

struct Inputs: Sendable {
    var now: Double
    var boot: String
    var mode: ModeState?
    var leases: [LeaseEntry]
    var battery: Battery?
    var thermal: Thermal
    var guards: Guards
    /// Sleep Now and logout keep the flag off until this time.
    var releaseUntil: Double?
}

/// Something that wants the Mac running with the lid closed.
struct Hold: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case on
        case agent(String)
        case command
        case timer
    }

    var kind: Kind
    var name: String
    /// The project for an agent, the program for a command.
    var detail: String? = nil
    var since: Double? = nil
    var until: Double? = nil
    /// An agent turn that ended less than a minute ago.
    var finishing = false
}

struct Decision: Equatable, Sendable {
    var mode: Mode
    var holds: [Hold] = []
    /// Why a guard keeps the Mac sleeping anyway.
    var pause: String? = nil
    var guards = Guards()
    var released = false
    /// Lease files that no longer matter.
    var expired: [String] = []

    var awake: Bool { !holds.isEmpty && pause == nil && !released }
}

enum EnergyAction: Equatable, Sendable {
    case none
    /// Save the user's battery energy mode, then switch to Low Power.
    case lower(save: Int)
    /// Put back the saved battery energy mode.
    case restore(Int)
    /// The user changed the mode meanwhile: keep it and forget the saved one.
    case keep
}

enum Policy {
    static let expiry: Double = 15 * 60
    static let grace: Double = 60
    static let tombstoneLife: Double = 10 * 60
    static let lowBattery = 20
    static let batteryResume = 25
    static let hot = 40.0
    static let coolResume = 36.0
    static let lowPower = 1

    static func decide(_ i: Inputs) -> Decision {
        let mode = effectiveMode(i.mode, boot: i.boot)
        var d = Decision(mode: mode)
        if mode == .on {
            d.holds.append(Hold(kind: .on, name: "on"))
        }

        for e in i.leases.sorted(by: { $0.lease.started < $1.lease.started }) {
            let l = e.lease
            switch e.kind {
            case .agent:
                if l.isRunning, let seen = l.lastSeen {
                    if e.pidAlive && i.now - seen < expiry {
                        if mode == .auto {
                            d.holds.append(Hold(kind: .agent(l.agent ?? "agent"), name: e.name, detail: l.project,
                                                since: l.started))
                        }
                    } else {
                        d.expired.append(e.name)
                    }
                } else if let end = l.endedAt {
                    // A turn that was live when it ended keeps the Mac up a minute longer, so the agent
                    // can finish writing and a queued prompt can start.
                    let wasLive = l.lastSeen.map { end - $0 < expiry } ?? false
                    if wasLive && i.now - end < grace {
                        if mode == .auto {
                            d.holds.append(Hold(kind: .agent(l.agent ?? "agent"), name: e.name, detail: l.project,
                                                since: l.started, finishing: true))
                        }
                    } else if i.now - end >= tombstoneLife {
                        d.expired.append(e.name)
                    }
                } else {
                    d.expired.append(e.name)
                }
            case .run:
                if e.pidAlive {
                    d.holds.append(Hold(kind: .command, name: e.name, detail: l.command, since: l.started))
                } else {
                    d.expired.append(e.name)
                }
            case .timer:
                if let until = l.until, until > i.now {
                    d.holds.append(Hold(kind: .timer, name: e.name, since: l.started, until: until))
                } else {
                    d.expired.append(e.name)
                }
            }
        }

        if let b = i.battery {
            d.guards.battery = !b.charging && (b.level <= lowBattery || (i.guards.battery && b.level <= batteryResume))
            if let t = b.temperature {
                d.guards.heat = t >= hot || (i.guards.heat && t >= coolResume)
            }
            if d.guards.battery {
                d.pause = "battery at \(b.level) %"
            } else if d.guards.heat, let t = b.temperature {
                d.pause = String(format: "battery at %.1f °C", t)
            }
        }
        if d.pause == nil && i.thermal >= .serious {
            d.pause = "thermal state \(i.thermal == .critical ? "critical" : "serious")"
        }
        d.released = (i.releaseUntil ?? 0) > i.now
        return d
    }

    /// Whether `energyPlan` needs the current battery energy mode, which costs a pmset run.
    static func energyNeedsCurrent(wantLow: Bool, saved: Int?) -> Bool {
        wantLow ? saved == nil : saved != nil
    }

    static func energyPlan(wantLow: Bool, saved: Int?, current: Int?) -> EnergyAction {
        guard let current else { return .none }
        if wantLow {
            return saved == nil && current != lowPower ? .lower(save: current) : .none
        }
        guard let saved else { return .none }
        return current == lowPower ? .restore(saved) : .keep
    }

    /// "90s", "90m", "2h" or "1h30m" in seconds.
    static func duration(_ text: String) -> Double? {
        let units: [Character: Double] = ["h": 3600, "m": 60, "s": 1]
        var total = 0.0, number = "", seen: [Character] = []
        for c in text {
            if c.isASCII && c.isNumber {
                number.append(c)
            } else if let unit = units[c], let n = Double(number), !seen.contains(c),
                      seen.allSatisfy({ units[$0]! > unit }) {
                total += n * unit
                number = ""
                seen.append(c)
            } else {
                return nil
            }
        }
        return number.isEmpty && total > 0 ? total : nil
    }
}

extension Lease {
    /// The latest activity is newer than the latest end.
    var isRunning: Bool {
        guard let lastSeen else { return false }
        return lastSeen > (endedAt ?? -.infinity)
    }

    /// Applies one hook event stamped with the time its hook process started. The result doesn't
    /// depend on the order events arrive in: activity stamped before the latest end can't revive
    /// the lease, and an end stamped before the latest activity can't end it.
    static func applying(_ event: HookEvent, stamp: Double, agent: String, sessionId: String,
                         pid: Int32?, project: String?, to old: Lease?, now: Double) -> Lease {
        var lease = old ?? Lease(agent: agent, sessionId: sessionId, started: stamp)
        if let pid { lease.pid = pid }
        if let project { lease.project = project }
        switch event {
        case .activity:
            let wasCurrent = old.map { $0.isRunning && now - ($0.lastSeen ?? 0) < Policy.expiry } ?? false
            lease.lastSeen = max(lease.lastSeen ?? stamp, stamp)
            if !wasCurrent && lease.isRunning {
                lease.started = stamp
            }
        case .end:
            lease.endedAt = max(lease.endedAt ?? stamp, stamp)
        }
        return lease
    }
}

extension Policy {
    /// The mode in force: On ends when the Mac restarts and falls back to the mode it replaced.
    static func effectiveMode(_ state: ModeState?, boot: String) -> Mode {
        guard let state else { return .off }
        if state.mode == .on && state.boot != boot {
            return state.base == .auto ? .auto : .off
        }
        return state.mode
    }

    /// The mode file after setting `mode`.
    static func setting(_ mode: Mode, from old: ModeState?, boot: String) -> ModeState {
        guard mode == .on else { return ModeState(mode: mode) }
        let current = effectiveMode(old, boot: boot)
        let base = current == .on ? (old?.base ?? .off) : current
        return ModeState(mode: .on, base: base, boot: boot)
    }
}
