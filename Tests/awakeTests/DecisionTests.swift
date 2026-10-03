import Testing
@testable import awake

private let now = 1_790_000_000.0

private func agent(_ session: String, project: String = "toybox", lastSeen: Double?, endedAt: Double? = nil,
                   alive: Bool = true) -> LeaseEntry {
    LeaseEntry(name: "claude-\(session)", kind: .agent,
               lease: Lease(agent: "claude", sessionId: session, pid: 4242, project: project,
                            started: lastSeen ?? endedAt ?? now, lastSeen: lastSeen, endedAt: endedAt),
               pidAlive: alive)
}

private func inputs(_ mode: Mode = .auto, leases: [LeaseEntry] = [],
                    battery: Battery? = Battery(level: 80, charging: false, external: false, temperature: 30),
                    thermal: Thermal = .nominal, guards: Guards = Guards(),
                    modeBoot: String = "boot-1", base: Mode? = nil, release: Double? = nil) -> Inputs {
    Inputs(now: now, boot: "boot-1", mode: ModeState(mode: mode, base: base, boot: modeBoot), leases: leases,
           battery: battery, thermal: thermal, guards: guards, releaseUntil: release)
}

@Suite struct Sessions {
    @Test func oneSessionFinishingWhileAnotherStillRuns() {
        let running = agent("a", project: "toybox", lastSeen: now - 30)
        let finished = agent("b", project: "redn", lastSeen: now - 400, endedAt: now - 200)
        let d = Policy.decide(inputs(leases: [running, finished]))
        #expect(d.awake)
        #expect(d.holds.map(\.name) == ["claude-a"])
        #expect(d.holds.first?.detail == "toybox")
    }

    @Test func expiresFifteenMinutesAfterTheLastHook() {
        #expect(Policy.decide(inputs(leases: [agent("a", lastSeen: now - 899)])).awake)
        let d = Policy.decide(inputs(leases: [agent("a", lastSeen: now - 900)]))
        #expect(!d.awake)
        #expect(d.expired == ["claude-a"])
    }

    @Test func deadAgentProcessEndsItsLease() {
        let d = Policy.decide(inputs(leases: [agent("a", lastSeen: now - 5, alive: false)]))
        #expect(!d.awake)
        #expect(d.expired == ["claude-a"])
    }

    @Test func endedTurnHoldsOneMoreMinute() {
        let finishing = Policy.decide(inputs(leases: [agent("a", lastSeen: now - 100, endedAt: now - 59)]))
        #expect(finishing.awake)
        #expect(finishing.holds.first?.finishing == true)

        let done = Policy.decide(inputs(leases: [agent("a", lastSeen: now - 100, endedAt: now - 60)]))
        #expect(!done.awake)
        #expect(done.expired.isEmpty, "the tombstone stays to absorb late hooks")

        let old = Policy.decide(inputs(leases: [agent("a", lastSeen: now - 1000, endedAt: now - 600)]))
        #expect(old.expired == ["claude-a"])
    }

    @Test func closingAnIdleSessionGetsNoGrace() {
        // SessionEnd for a session whose lease was already cleaned up: nothing ran.
        #expect(!Policy.decide(inputs(leases: [agent("a", lastSeen: nil, endedAt: now - 5)])).awake)
        // A turn that went quiet past the expiry and only then ended.
        #expect(!Policy.decide(inputs(leases: [agent("a", lastSeen: now - 1000, endedAt: now - 5)])).awake)
    }

    @Test func agentLeasesCountOnlyInAuto() {
        let lease = [agent("a", lastSeen: now - 5)]
        #expect(Policy.decide(inputs(.auto, leases: lease)).awake)
        #expect(!Policy.decide(inputs(.off, leases: lease)).awake)
        #expect(Policy.decide(inputs(.on, leases: lease)).holds.map(\.kind) == [.on])
    }

    @Test func missingModeFileMeansOff() {
        var i = inputs(leases: [agent("a", lastSeen: now - 5)])
        i.mode = nil
        let d = Policy.decide(i)
        #expect(d.mode == .off)
        #expect(!d.awake)
    }
}

@Suite struct CommandsAndTimers {
    let run = LeaseEntry(name: "run-321", kind: .run, lease: Lease(pid: 321, command: "make", started: now - 40),
                         pidAlive: true)
    let timer = LeaseEntry(name: "for-x", kind: .timer, lease: Lease(started: now - 10, until: now + 60),
                           pidAlive: true)

    @Test func countInOff() {
        #expect(Policy.decide(inputs(.off, leases: [run])).awake)
        #expect(Policy.decide(inputs(.off, leases: [timer])).awake)
        let d = Policy.decide(inputs(.off, leases: [run, timer]))
        #expect(d.holds.map(\.kind) == [.command, .timer])
        #expect(d.holds.first?.detail == "make")
    }

    @Test func endWithTheirProcessOrDeadline() {
        var deadRun = run
        deadRun.pidAlive = false
        var overTimer = timer
        overTimer.lease.until = now
        let d = Policy.decide(inputs(.off, leases: [deadRun, overTimer]))
        #expect(!d.awake)
        #expect(d.expired.sorted() == ["for-x", "run-321"])
    }
}

@Suite struct Guarding {
    let working = [agent("a", lastSeen: now - 5)]

    @Test func batteryGuardTreatsAnAttachedChargerThatIsNotChargingAsBattery() {
        let plugged = Battery(level: 20, charging: false, external: true, temperature: 30)
        let d = Policy.decide(inputs(leases: working, battery: plugged))
        #expect(!d.awake)
        #expect(d.guards.battery)
        #expect(d.pause != nil)
    }

    @Test(arguments: [
        (level: 21, charging: false, wasPaused: false, paused: false),
        (level: 20, charging: false, wasPaused: false, paused: true),
        (level: 25, charging: false, wasPaused: true, paused: true),
        (level: 26, charging: false, wasPaused: true, paused: false),
        (level: 10, charging: true, wasPaused: true, paused: false),
    ])
    func batteryGuardResumesAbove25PercentOrOnceCharging(level: Int, charging: Bool, wasPaused: Bool, paused: Bool) {
        let b = Battery(level: level, charging: charging, external: charging, temperature: 30)
        let d = Policy.decide(inputs(leases: working, battery: b, guards: Guards(battery: wasPaused)))
        #expect(d.guards.battery == paused)
        #expect(d.awake == !paused)
    }

    @Test(arguments: [
        (temperature: 39.9, wasPaused: false, paused: false),
        (temperature: 40.0, wasPaused: false, paused: true),
        (temperature: 36.0, wasPaused: true, paused: true),
        (temperature: 35.9, wasPaused: true, paused: false),
    ])
    func heatGuardPausesAt40AndResumesBelow36(temperature: Double, wasPaused: Bool, paused: Bool) {
        let b = Battery(level: 80, charging: false, external: false, temperature: temperature)
        let d = Policy.decide(inputs(leases: working, battery: b, guards: Guards(heat: wasPaused)))
        #expect(d.guards.heat == paused)
        #expect(d.awake == !paused)
    }

    @Test func seriousThermalStatePauses() {
        #expect(Policy.decide(inputs(leases: working, thermal: .fair)).awake)
        #expect(!Policy.decide(inputs(leases: working, thermal: .serious)).awake)
        #expect(!Policy.decide(inputs(leases: working, thermal: .critical)).awake)
    }

    @Test func guardsPauseOnToo() {
        let low = Battery(level: 15, charging: false, external: false, temperature: 30)
        let d = Policy.decide(inputs(.on, battery: low))
        #expect(d.mode == .on)
        #expect(!d.awake)
    }

    @Test func noBatteryMeansNoBatteryGuards() {
        #expect(Policy.decide(inputs(leases: working, battery: nil)).awake)
    }

    @Test func sleepNowReleasesEvenWhileHeld() {
        let d = Policy.decide(inputs(.on, release: now + 30))
        #expect(d.released)
        #expect(!d.awake)
        #expect(Policy.decide(inputs(.on, release: now - 1)).awake)
    }
}

@Suite struct Reboot {
    @Test func onEndsAtRebootAndFallsBackToWhatItReplaced() {
        let auto = Policy.decide(inputs(.on, modeBoot: "boot-0", base: .auto))
        #expect(auto.mode == .auto)
        #expect(!auto.awake)

        let autoWithTurn = Policy.decide(inputs(.on, leases: [agent("a", lastSeen: now - 5)], modeBoot: "boot-0", base: .auto))
        #expect(autoWithTurn.holds.map(\.name) == ["claude-a"])

        #expect(Policy.decide(inputs(.on, modeBoot: "boot-0", base: .off)).mode == .off)
        #expect(Policy.decide(inputs(.on, modeBoot: "boot-0")).mode == .off)
    }

    @Test func onHoldsWithinItsBoot() {
        let d = Policy.decide(inputs(.on))
        #expect(d.awake)
        #expect(d.holds.map(\.kind) == [.on])
    }
}

@Suite struct EnergyMode {
    @Test(arguments: [
        (wantLow: true, saved: nil, current: 0, want: EnergyAction.lower(save: 0)),
        (wantLow: true, saved: nil, current: 2, want: .lower(save: 2)),
        (wantLow: true, saved: nil, current: 1, want: .none),
        (wantLow: true, saved: nil, current: nil, want: .none),
        (wantLow: true, saved: 0, current: 1, want: .none),
        (wantLow: false, saved: 0, current: 1, want: .restore(0)),
        (wantLow: false, saved: 2, current: 1, want: .restore(2)),
        (wantLow: false, saved: 0, current: 2, want: .keep),
        (wantLow: false, saved: 0, current: nil, want: .none),
        (wantLow: false, saved: nil, current: 1, want: .none),
    ] as [(wantLow: Bool, saved: Int?, current: Int?, want: EnergyAction)])
    func savesLowersAndRestoresUnlessTheUserChangedIt(wantLow: Bool, saved: Int?, current: Int?, want: EnergyAction) {
        #expect(Policy.energyPlan(wantLow: wantLow, saved: saved, current: current) == want)
    }

    @Test(arguments: [
        (wantLow: true, saved: nil, needs: true),
        (wantLow: true, saved: 0, needs: false),
        (wantLow: false, saved: 0, needs: true),
        (wantLow: false, saved: nil, needs: false),
    ] as [(wantLow: Bool, saved: Int?, needs: Bool)])
    func readsTheCurrentModeOnlyWhenItMightAct(wantLow: Bool, saved: Int?, needs: Bool) {
        #expect(Policy.energyNeedsCurrent(wantLow: wantLow, saved: saved) == needs)
    }
}

@Suite struct ModeSetting {
    @Test(arguments: [
        (from: ModeState(mode: .auto), set: Mode.on, want: ModeState(mode: .on, base: .auto, boot: "boot-1")),
        (from: ModeState(mode: .off), set: .on, want: ModeState(mode: .on, base: .off, boot: "boot-1")),
        (from: nil, set: .on, want: ModeState(mode: .on, base: .off, boot: "boot-1")),
        (from: ModeState(mode: .on, base: .auto, boot: "boot-1"), set: .on,
         want: ModeState(mode: .on, base: .auto, boot: "boot-1")),
        (from: ModeState(mode: .on, base: .auto, boot: "boot-0"), set: .on,
         want: ModeState(mode: .on, base: .auto, boot: "boot-1")),
        (from: ModeState(mode: .on, base: .auto, boot: "boot-1"), set: .off, want: ModeState(mode: .off)),
        (from: ModeState(mode: .off), set: .auto, want: ModeState(mode: .auto)),
    ] as [(from: ModeState?, set: Mode, want: ModeState)])
    func onRemembersWhatItReplacedAndItsBoot(from: ModeState?, set: Mode, want: ModeState) {
        #expect(Policy.setting(set, from: from, boot: "boot-1") == want)
    }
}

@Suite struct ReleaseWindow {
    @Test func endsWhenTheMacRestarts() {
        var i = Inputs(now: 1_790_000_000, boot: "boot-1", mode: ModeState(mode: .on, base: .auto, boot: "boot-1"),
                       leases: [], battery: nil, thermal: .nominal, guards: Guards(),
                       releaseUntil: 1_790_000_060, releaseBoot: "boot-0")
        #expect(Policy.decide(i).awake)
        i.releaseBoot = "boot-1"
        #expect(!Policy.decide(i).awake)
    }
}
