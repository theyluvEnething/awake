import Foundation

/// The names the app, its privileged helper and their launchd jobs go by. The helper's launchd
/// label, Mach service and code signing identifier are all `helper`. The menu's launchd label
/// differs from the app's bundle identifier: macOS files a login item labelled like its app under
/// the app itself and never starts it.
enum Identity {
    static let app = "io.github.theyluvenething.awake"
    static let helper = "io.github.theyluvenething.awake.helper"
    static let menu = "io.github.theyluvenething.awake.menu"
    static let reconcile = "io.github.theyluvenething.awake.reconcile"
}

/// Everything the helper does as root, named by the pmset arguments it runs: lid sleep on or off,
/// and the battery energy mode. A request carries one of these names. Any other text fails to
/// decode, so the helper never runs arguments a caller made up.
enum PowerCommand: String, Codable, CaseIterable, Sendable {
    case lidSleepOn = "disablesleep 0"
    case lidSleepOff = "disablesleep 1"
    case energyAutomatic = "powermode 0"
    case energyLow = "powermode 1"
    case energyHigh = "powermode 2"

    /// The kernel's SleepDisabled flag: set, closing the lid keeps the Mac running.
    init(sleepDisabled: Bool) {
        self = sleepDisabled ? .lidSleepOff : .lidSleepOn
    }

    /// The battery energy modes of `pmset -b powermode`: 0 automatic, 1 low power, 2 high power.
    init?(batteryEnergyMode mode: Int) {
        switch mode {
        case 0: self = .energyAutomatic
        case 1: self = .energyLow
        case 2: self = .energyHigh
        default: return nil
        }
    }

    /// The arguments the helper passes to /usr/bin/pmset.
    var arguments: [String] {
        switch self {
        case .lidSleepOn: ["-a", "disablesleep", "0"]
        case .lidSleepOff: ["-a", "disablesleep", "1"]
        case .energyAutomatic: ["-b", "powermode", "0"]
        case .energyLow: ["-b", "powermode", "1"]
        case .energyHigh: ["-b", "powermode", "2"]
        }
    }
}

/// One message to the helper.
struct PowerRequest: Codable, Sendable {
    var command: PowerCommand
}

/// The helper's answer: nil when pmset succeeded, otherwise what went wrong.
struct PowerReply: Codable, Sendable {
    var error: String?
}
