import Foundation

/// Text for the menu, the settings window and `awake status`.
enum Format {
    /// "40 s", "12 min", "1h 12m".
    static func age(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = s % 3600 / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "Claude · invariance · 12 min", "Command · make · 40 s", "Timer · 1h 12m left".
    static func label(_ hold: Hold, now: Double) -> String {
        let age = hold.finishing ? "finishing" : Self.age(now - (hold.since ?? now))
        switch hold.kind {
        case .on:
            return "Stay awake indefinitely"
        case .agent(let agent):
            return ([agent.prefix(1).uppercased() + agent.dropFirst(), hold.detail, age] as [String?])
                .compactMap { $0 }.joined(separator: " · ")
        case .command:
            return ["Command", hold.detail, age].compactMap { $0 }.joined(separator: " · ")
        case .timer:
            return "Timer · \(Self.age((hold.until ?? now) - now)) left"
        }
    }
}
