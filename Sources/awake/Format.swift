import Foundation

/// Every text the menu, the Settings window, `awake status`, `awake help` and the log show, so a
/// thing reads the same everywhere. Phrases that can stand mid-sentence start lowercase;
/// `capitalized` and `sentence` turn them into a label or a sentence where they stand alone.
enum Format {
    // MARK: Modes and lid sleep

    /// The UI's names for `off`, `auto` and `on`.
    static func mode(_ mode: Mode) -> String {
        switch mode {
        case .off: "Off"
        case .auto: "Awake"
        case .on: "Stay awake indefinitely"
        }
    }

    /// What a mode does, under its toggle in Settings and in `awake help`.
    static func explain(_ mode: Mode) -> String {
        switch mode {
        case .off: lidEffect(false)
        case .auto: "keeps the Mac running with the lid closed while Claude or Codex works"
        case .on: "even when nothing runs, until you turn it off, restart or log out"
        }
    }

    /// Lid sleep is the flag seen from the lid: off while the flag keeps the Mac running.
    static func lidSleep(_ flag: Bool) -> String { flag ? "Off" : "On" }

    static func lidEffect(_ flag: Bool) -> String {
        flag ? "closing the lid keeps the Mac running" : "closing the lid puts the Mac to sleep"
    }

    /// The flag is no longer what awake last set it to.
    static func changedOutside(flag: Bool) -> String {
        "lid sleep was turned \(lidSleep(flag).lowercased()) outside Awake"
    }

    // MARK: Holds

    /// "40 s", "12 min", "1 h 12 min".
    static func age(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = s % 3600 / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "Claude · invariance · 12 min", "Command · make · 40 s", "Timer · 1 h 12 min left".
    static func hold(_ hold: Hold, now: Double) -> String {
        let age = hold.finishing ? "finishing" : Self.age(now - (hold.since ?? now))
        switch hold.kind {
        case .on:
            return mode(.on)
        case .agent(let agent):
            return [capitalized(agent), hold.detail, age].compactMap { $0 }.joined(separator: " · ")
        case .command:
            return ["Command", hold.detail, age].compactMap { $0 }.joined(separator: " · ")
        case .timer:
            return "Timer · \(Self.age((hold.until ?? now) - now)) left"
        }
    }

    // MARK: Power

    /// "80 %, on battery, 29.8 °C".
    static func battery(_ b: Battery) -> String {
        let power = b.charging ? "charging" : b.external ? "plugged in, not charging" : "on battery"
        return ["\(b.level) %", power, b.temperature.map(degrees)].compactMap { $0 }.joined(separator: ", ")
    }

    /// "raw 4612/6008 mAh, -9.8 W" for the log, or nil when the battery doesn't report it.
    static func batteryRaw(_ b: Battery) -> String? {
        guard let charge = b.rawCharge, let max = b.rawMax else { return nil }
        let watts = b.watts.map { String(format: "%+.1f W", $0) }
        return ["raw \(charge)/\(max) mAh", watts].compactMap { $0 }.joined(separator: ", ")
    }

    static func thermal(_ t: Thermal) -> String {
        switch t {
        case .nominal: "Normal"
        case .fair: "Elevated"
        case .serious: "High"
        case .critical: "Critical"
        }
    }

    static func thermalState(_ t: Thermal) -> String { "thermal state \(thermal(t).lowercased())" }

    /// The Low Power row: whether awake has switched the battery energy mode to Low Power, which it
    /// does while the Mac runs on battery with the lid closed.
    static func lowPower(setByAwake: Bool) -> String {
        setByAwake ? "On while the lid is closed" : "With the lid closed on battery"
    }

    /// The battery energy modes of `pmset -b powermode`.
    static func energyMode(_ mode: Int) -> String {
        switch mode {
        case 0: "Automatic"
        case 1: "Low Power"
        case 2: "High Power"
        default: "mode \(mode)"
        }
    }

    /// "battery at 18 %", "battery at 40.2 °C", "thermal state high".
    static func pause(_ pause: Pause) -> String {
        switch pause {
        case .battery(let level): "battery at \(level) %"
        case .heat(let t): "battery at \(degrees(t))"
        case .thermal(let t): thermalState(t)
        }
    }

    static func paused(_ pause: Pause) -> String { "Paused: \(Self.pause(pause))" }

    /// When the guards pause, under the power rows in Settings.
    static let guards = "Awake lets the Mac sleep at \(Policy.lowBattery) % battery unless it's charging, at "
        + "\(Int(Policy.hot)) °C battery temperature and when the thermal state is "
        + "\(thermal(.serious).lowercased()) or \(thermal(.critical).lowercased())."

    // MARK: Setup

    static let setupPurpose = "Keeps your Mac running with the lid closed while Claude Code or Codex works."
    static let setupLocation = "Move Awake.app to /Applications, then open it there. Hooks and the command line "
        + "use /Applications/Awake.app, and macOS registers its helper and login items at that location. "
        + "Setup cannot run from Downloads, a disk image or App Translocation."
    static let setupHelper = "Runs as root. It can only turn lid sleep on or off and switch the battery energy mode. "
        + "It turns lid sleep back on when your Mac starts. macOS asks you to allow it in System Settings."
    static let setupHelperCommands = "pmset -a disablesleep 0|1\npmset -b powermode 0|1|2"
    static let setupLoginItems = "The menu at login, plus a check every 30 seconds."
    static let setupApproval = "Switch on Awake under Allow in the Background."
    static let setupCodex = "Adds Awake's hooks beside your own in ~/.codex/hooks.json."
    static let setupCodexTrust = "Trust the hooks once with /hooks in Codex."
    static let setupCodexMissing = "Codex isn't installed"
    static let setupCodexLater = "Open Awake again after installing Codex to add its hooks."
    static let setupClaude = "Add the copied hooks to ~/.claude/settings.json. Awake never writes Claude Code settings."
    static let setupClaudeManaged = "If managed settings control hooks, such as allowManagedHooksOnly, "
        + "an administrator must add them to:"
    static let setupClaudeManagedPath = "/Library/Application Support/ClaudeCode/managed-settings.json"

    static let uninstallDescription = "Awake will turn Off, end every hold, restore lid sleep and your battery energy mode, "
        + "remove its helper, two login items, Codex hooks, state and log, then move Awake.app to the Trash and quit.\n\n"
        + "Claude Code hooks you added stay in your settings. They do nothing once the app is gone. "
        + "If the app cannot be moved to the Trash, Finder will show it for you to remove."

    static func uninstallRecovery(savedEnergy: Int?) -> String {
        var text = "Lid sleep may still be off. Allow Awake's helper in System Settings and try again, "
            + "or run this in Terminal with an administrator password:\n\nsudo pmset -a disablesleep 0"
        if let savedEnergy, (0...2).contains(savedEnergy) {
            text += "\n\nsudo pmset -b powermode \(savedEnergy)\n\nThe second command restores your battery energy mode."
        }
        return text
    }

    // MARK: Text

    static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    static func sentence(_ text: String) -> String { capitalized(text) + "." }

    private static func degrees(_ celsius: Double) -> String { String(format: "%.1f °C", celsius) }
}
