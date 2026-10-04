import Foundation
import IOKit
import Synchronization
import XPC

/// The machine's power state, read without root, and the few privileged pmset commands the
/// signed helper allows.
enum System {
    static func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The kernel's SleepDisabled flag (what awake owns) and whether the lid is closed.
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
        privilegedPmset(PowerCommand(sleepDisabled: on))
    }

    static func setBatteryEnergyMode(_ mode: Int) -> String? {
        guard let command = PowerCommand(batteryEnergyMode: mode) else {
            return "the battery energy mode is invalid: choose 0, 1 or 2"
        }
        return privilegedPmset(command)
    }

    /// Asks for system sleep. Works without root for the logged-in user, but not while SleepDisabled is set.
    static func sleepNow() {
        _ = run("/usr/bin/pmset", ["sleepnow"])
    }

    /// One authenticated request, with a bounded wait even in a hook process with no run loop.
    private static func privilegedPmset(_ command: PowerCommand) -> String? {
        let deadline = DispatchTime.now() + 10
        let arrived = DispatchSemaphore(value: 0)
        let answer = Mutex<PowerReply?>(nil)
        let finish: @Sendable (PowerReply) -> Void = { reply in
            let first = answer.withLock { value in
                guard value == nil else { return false }
                value = reply
                return true
            }
            if first { arrived.signal() }
        }
        do {
            let session = try XPCSession(machService: Identity.helper, targetQueue: .global(qos: .utility),
                                         options: .privileged,
                                         requirement: .isFromSameTeam(andMatchesSigningIdentifier: Identity.helper),
                                         cancellationHandler: { error in
                                             finish(PowerReply(error: helperError(error)))
                                         })
            defer { session.cancel(reason: "power request finished") }
            try session.send(PowerRequest(command: command)) { (result: Result<PowerReply, any Error>) in
                switch result {
                case .success(let reply):
                    finish(PowerReply(error: reply.error.map { "\($0); open Awake and try again" }))
                case .failure(let error):
                    finish(PowerReply(error: helperError(error)))
                }
            }
            guard arrived.wait(timeout: deadline) == .success else {
                return "the helper didn't answer within 10 seconds: open Awake and try again"
            }
            return answer.withLock { $0?.error }
        } catch {
            return helperError(error)
        }
    }

    private static func helperError(_ error: any Error) -> String {
        // XPCRichError has no reason code. Only distinguish signing when XPC says so explicitly.
        if let error = error as? XPCRichError,
           error.debugDescription.lowercased().contains("code signing") {
            return "the helper's signature couldn't be verified: reinstall Awake and open it to finish setup"
        }
        if error is DecodingError {
            return "the helper sent an unreadable reply: reinstall Awake and open it to finish setup"
        }
        return "the helper couldn't be reached: open Awake to finish setup"
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
