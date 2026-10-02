import Testing
@testable import awake

private let now = 1_790_000_000.0

@Suite struct Formatting {
    @Test(arguments: [
        (0.0, "0 s"), (40, "40 s"), (59.9, "59 s"), (60, "1 min"), (750, "12 min"), (3599, "59 min"),
        (3600, "1h"), (4320, "1h 12m"), (7260, "2h 1m"),
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
        (Hold(kind: .timer, name: "for-1", since: now - 60, until: now + 4320), "Timer · 1h 12m left"),
        (Hold(kind: .on, name: "on"), "Stay awake indefinitely"),
    ] as [(Hold, String)])
    func holdLabels(hold: Hold, text: String) {
        #expect(Format.label(hold, now: now) == text)
    }
}
