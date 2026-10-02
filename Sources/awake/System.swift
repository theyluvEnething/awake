import Foundation
import IOKit

/// The machine's power state, read without root, and the few privileged pmset commands the
/// sudoers rule allows.
enum System {
    static func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The kernel's SleepDisabled switch (what awake owns) and whether the lid is closed.
    static func rootDomain() -> (sleepDisabled: Bool, lidClosed: Bool) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain"))
        guard service != 0 else { return (false, false) }
        defer { IOObjectRelease(service) }
        return (property(service, "SleepDisabled") as? Bool ?? false,
                property(service, "AppleClamshellState") as? Bool ?? false)
    }

    static func battery() -> Battery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let current = property(service, "CurrentCapacity") as? Int,
              let max = property(service, "MaxCapacity") as? Int, max > 0 else { return nil }
        return Battery(level: current * 100 / max,
                       charging: property(service, "IsCharging") as? Bool ?? false,
                       external: property(service, "ExternalConnected") as? Bool ?? false,
                       temperature: (property(service, "Temperature") as? Int).map { Double($0) / 100 })
    }

    static func thermal() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    /// The battery energy mode from `pmset -g custom`: 0 automatic, 1 low power, 2 high power.
    static func batteryEnergyMode() -> Int? {
        var inBattery = false
        for line in run("/usr/bin/pmset", ["-g", "custom"]).output.split(separator: "\n") {
            if line.hasSuffix(":") {
                inBattery = line.hasPrefix("Battery Power")
            } else if inBattery {
                let words = line.split(separator: " ")
                if words.first == "powermode", let value = words.last.flatMap({ Int($0) }) { return value }
            }
        }
        return nil
    }

    /// Returns nil on success, otherwise what went wrong.
    static func setSleepDisabled(_ on: Bool) -> String? {
        privilegedPmset(["-a", "disablesleep", on ? "1" : "0"])
    }

    static func setBatteryEnergyMode(_ mode: Int) -> String? {
        privilegedPmset(["-b", "powermode", String(mode)])
    }

    /// Asks for system sleep. Works without root for the logged-in user, but not while SleepDisabled is set.
    static func sleepNow() {
        _ = run("/usr/bin/pmset", ["sleepnow"])
    }

    private static func privilegedPmset(_ args: [String]) -> String? {
        let result = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args)
        if result.status == 0 { return nil }
        if result.error.contains("password is required") || result.error.contains("not allowed") {
            return "the sudo rule is missing: run mac-setup's scripts/admin.sh"
        }
        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return "pmset \(args.joined(separator: " ")) failed" + (detail.isEmpty ? "" : ": \(detail)")
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "\(error)") }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
    }
}
