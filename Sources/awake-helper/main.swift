import Darwin
import Foundation
import XPC
import os

/// Only the five commands in PowerCommand can reach pmset, and only one runs at a time.
private enum Helper {
    static let log = Logger(subsystem: Identity.helper, category: "power")
    static let commands = DispatchQueue(label: Identity.helper + ".pmset")
    static let caller = XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier: Identity.app)

    /// Lid sleep back on once per boot, because macOS keeps disablesleep across a restart. A
    /// relaunch later in the same boot must not turn it on in the middle of a turn, so a marker in
    /// /var/run, which macOS empties at boot, records that the reset worked.
    static func resetAtBoot() {
        let marker = "/var/run/" + Identity.helper + ".didRunThisBoot"
        var info = stat()
        if lstat(marker, &info) == 0 { return }
        guard errno == ENOENT else {
            log.fault("couldn't check the boot marker")
            exit(1)
        }
        // powerd may still be starting this early in the boot. Without a success there's no
        // marker, and the next start tries again.
        for attempt in 1...3 {
            if commands.sync(execute: { execute(.lidSleepOn) }).error == nil {
                let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                if fd >= 0 {
                    close(fd)
                } else if errno != EEXIST {
                    log.fault("couldn't create the boot marker")
                }
                return
            }
            log.error("boot reset failed, attempt \(attempt)")
            sleep(2)
        }
    }

    /// A request that waited behind a stuck pmset is dropped once its caller has stopped waiting:
    /// callers wait 10 seconds, and a request that starts within 4 finishes within 9.
    static func run(_ command: PowerCommand, received: ContinuousClock.Instant) -> PowerReply {
        commands.sync {
            guard received.duration(to: .now) < .seconds(4) else {
                log.error("dropped \(command.rawValue, privacy: .public) after waiting too long")
                return PowerReply(error: "the helper was busy: try again")
            }
            return execute(command)
        }
    }

    /// Turns lid sleep back on and quits: nothing else would turn it on once the helper is gone.
    static func restoreAndExit(_ reason: StaticString) -> Never {
        log.notice("\(reason, privacy: .public): turning lid sleep back on")
        _ = commands.sync { execute(.lidSleepOn) }
        exit(0)
    }

    /// Runs one command on the `commands` queue and gives pmset 5 seconds.
    private static func execute(_ command: PowerCommand) -> PowerReply {
        log.notice("running \(command.rawValue, privacy: .public)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = command.arguments
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        // One pipe for both streams, read after pmset exits: these commands print a line at most.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let failure = "pmset \(command.arguments.joined(separator: " ")) failed"
        do {
            try process.run()
        } catch {
            log.error("couldn't start \(command.rawValue, privacy: .public)")
            return PowerReply(error: failure + ": couldn't start pmset")
        }
        guard exited.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            log.error("stopped \(command.rawValue, privacy: .public) after 5 seconds")
            return PowerReply(error: failure + ": pmset didn't finish within 5 seconds")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            log.error("failed \(command.rawValue, privacy: .public)")
            let detail = String(String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300))
            return PowerReply(error: failure + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return PowerReply(error: nil)
    }

    static func executablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private struct PowerHandler: XPCPeerHandler {
    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        let received = ContinuousClock.now
        guard let request = try? message.decode(as: PowerRequest.self) else {
            Helper.log.error("refused an undecodable power request")
            return PowerReply(error: "the power request wasn't recognized: reinstall Awake")
        }
        return Helper.run(request.command, received: received)
    }

    func handleCancellation(error: XPCRichError) {
        if error.debugDescription.lowercased().contains("code signing") {
            Helper.log.error("refused a message because the caller's signature didn't match")
        } else {
            Helper.log.debug("xpc session ended")
        }
    }
}

guard geteuid() == 0 else {
    Helper.log.fault("the helper must be started as root by launchd")
    exit(1)
}
Helper.resetAtBoot()

// Switched off in System Settings, unregistered, or the Mac shuts down: launchd sends SIGTERM.
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { Helper.restoreAndExit("stopping") }
terminate.resume()

// Awake.app moved to the Trash without Uninstall leaves nothing that could turn lid sleep on.
let executable = Helper.executablePath()
let appGone = DispatchSource.makeTimerSource(queue: .main)
appGone.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
appGone.setEventHandler {
    if access(executable, F_OK) != 0 { Helper.restoreAndExit("the app is gone") }
}
appGone.resume()

do {
    let listener = try XPCListener(service: Identity.helper, requirement: Helper.caller) { request in
        request.accept { session in
            // The listener checks incoming connections; its sessions do not inherit that check.
            session.setPeerRequirement(Helper.caller)
            return PowerHandler()
        }
    }
    withExtendedLifetime(listener) { dispatchMain() }
} catch {
    Helper.log.fault("couldn't start the xpc listener")
    exit(1)
}
