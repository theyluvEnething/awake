import Testing
@testable import awake

private let now = 1_790_000_000.0

@Suite struct Formatting {
    @Test(arguments: [
        (0.0, "0 s"), (40, "40 s"), (59.9, "59 s"), (60, "1 min"), (750, "12 min"), (3599, "59 min"),
        (3600, "1 h"), (4320, "1 h 12 min"), (7260, "2 h 1 min"),
    ] as [(Double, String)])
    func ages(seconds: Double, text: String) {
        #expect(Format.age(seconds) == text)
    }

    @Test(arguments: [
        (Hold(kind: .agent("claude"), name: "claude-1", detail: "invariance", since: now - 720),
         "Claude · invariance · 12 min"),
        (Hold(kind: .agent("codex"), name: "codex-1", detail: "redn", since: now - 180, finishing: true),
         "Codex · redn · finishing"),
        (Hold(kind: .agent("claude"), name: "claude-2", since: now - 30), "Claude · 30 s"),
        (Hold(kind: .command, name: "run-1", detail: "make", since: now - 40), "Command · make · 40 s"),
        (Hold(kind: .timer, name: "for-1", since: now - 60, until: now + 4320), "Timer · 1 h 12 min left"),
        (Hold(kind: .on, name: "on"), "Stay awake indefinitely"),
    ] as [(Hold, String)])
    func holdLabels(hold: Hold, text: String) {
        #expect(Format.hold(hold, now: now) == text)
    }

    @Test(arguments: [
        (Battery(level: 80, charging: false, external: false, temperature: 30, rawCharge: 4612, rawMax: 6008,
                 watts: -9.84), "raw 4612/6008 mAh, -9.8 W"),
        (Battery(level: 15, charging: true, external: true, temperature: 30, rawCharge: 842, rawMax: 6008,
                 watts: 55.9), "raw 842/6008 mAh, +55.9 W"),
        (Battery(level: 15, charging: true, external: true, temperature: 30), nil),
    ] as [(Battery, String?)])
    func rawBatteryForTheLog(battery: Battery, text: String?) {
        #expect(Format.batteryRaw(battery) == text)
    }
}
