import Testing
@testable import awake

private let now = 1_790_000_000.0

private func apply(_ event: HookEvent, _ stamp: Double, to old: Lease?, pid: Int32? = 7) -> Lease {
    Lease.applying(event, stamp: stamp, agent: "claude", sessionId: "s1", pid: pid, project: "toybox", to: old, now: now)
}

@Suite struct HookEvents {
    @Test(arguments: [
        ("UserPromptSubmit", HookEvent.activity), ("PreToolUse", .activity), ("PostToolUse", .activity),
        ("PostToolUseFailure", .activity), ("Stop", .end), ("StopFailure", .end), ("SessionEnd", .end),
        ("Interrupt", .end),
    ] as [(String, HookEvent)])
    func classifiesTheEventsThatMatter(name: String, event: HookEvent) {
        #expect(HookEvent(name: name) == event)
    }

    @Test(arguments: ["SubagentStop", "Notification", "SessionStart", "PreCompact", ""])
    func ignoresTheRest(name: String) {
        #expect(HookEvent(name: name) == nil)
    }
}

@Suite struct Leases {
    @Test func toolEventStartsALeaseWithoutAPrompt() {
        let lease = apply(.activity, now - 3, to: nil)
        #expect(lease.isRunning)
        #expect(lease == Lease(agent: "claude", sessionId: "s1", pid: 7, project: "toybox",
                               started: now - 3, lastSeen: now - 3))
    }

    @Test func runningTurnKeepsItsStart() {
        let lease = apply(.activity, now - 1, to: apply(.activity, now - 50, to: nil))
        #expect(lease.started == now - 50)
        #expect(lease.lastSeen == now - 1)
    }

    @Test func stopLandingBeforeItsPromptLeavesTheTurnEnded() {
        let stopFirst = apply(.end, now - 1, to: nil)
        #expect(!stopFirst.isRunning)
        let promptLate = apply(.activity, now - 2, to: stopFirst)
        #expect(!promptLate.isRunning)
        #expect(promptLate.endedAt == now - 1)
    }

    @Test func staleStopDoesNotEndANewerTurn() {
        let newTurn = apply(.activity, now - 5, to: nil)
        let lateStop = apply(.end, now - 10, to: newTurn)
        #expect(lateStop.isRunning)
    }

    @Test func activityAfterTheEndStartsANewTurn() {
        let ended = Lease(agent: "claude", sessionId: "s1", pid: 7, project: "toybox",
                          started: now - 100, lastSeen: now - 60, endedAt: now - 50)
        let lease = apply(.activity, now - 1, to: ended)
        #expect(lease.isRunning)
        #expect(lease.started == now - 1)
    }

    @Test func activityAfterTheExpiryCountsAsANewStart() {
        let quiet = apply(.activity, now - 1000, to: nil)
        #expect(apply(.activity, now - 1, to: quiet).started == now - 1)
    }

    @Test func endWithoutAnOwnerKeepsTheKnownPid() {
        let ended = apply(.end, now - 1, to: apply(.activity, now - 9, to: nil), pid: nil)
        #expect(ended.pid == 7)
        #expect(ended.endedAt == now - 1)
    }
}

@Suite struct Durations {
    @Test(arguments: [("90s", 90.0), ("90m", 5400), ("2h", 7200), ("1h30m", 5400), ("1h5s", 3605)] as [(String, Double)])
    func parses(text: String, seconds: Double) {
        #expect(Policy.duration(text) == seconds)
    }

    @Test(arguments: ["", "45", "0m", "m", "1x", "1h 30m", "-5m", "30m1h"])
    func rejects(text: String) {
        #expect(Policy.duration(text) == nil)
    }
}
