import Foundation

enum Commands {
    static let usage = """
        usage: awake set off|auto|on   Off: sleep on lid close. Auto: stay up while Claude or Codex works.
                                       On: stay up until changed, a restart or logout.
               awake run -- <command>  keep the Mac running while the command runs, in any mode
               awake for 90m           keep it running for 90s, 90m, 2h or 1h30m, in any mode
               awake stop              end every run and for hold
               awake status            what awake sees and decides
               awake reconcile         apply the decision now (launchd runs this every 30 seconds)
        """

    /// `awake set off|auto|on`
    static func set(_ arg: String?) -> Int32 {
        guard let arg, let mode = Mode(rawValue: arg) else { return fail(usage) }
        let status = Store.withLock {
            Store.setMode(mode)
            return Reconcile.run(locked: true)
        } ?? nil
        report(status)
        return 0
    }

    /// `awake for <duration>`
    static func hold(_ arg: String?) -> Int32 {
        guard let arg, let seconds = Policy.duration(arg) else { return fail(usage) }
        let now = Date().timeIntervalSince1970
        let status = Store.withLock {
            Store.setLease("for-" + String(UInt64(now * 1000), radix: 36), Lease(started: now, until: now + seconds))
            return Reconcile.run(locked: true)
        } ?? nil
        print("Keeping the Mac running until \(Date(timeIntervalSince1970: now + seconds).formatted(date: .omitted, time: .shortened)). awake stop ends it sooner.")
        report(status)
        return 0
    }

    /// `awake stop`
    static func stop() -> Int32 {
        let ended = Store.withLock {
            let names = Store.leases().map(\.name).filter { $0.hasPrefix("run-") || $0.hasPrefix("for-") }
            names.forEach(Store.removeLease)
            Reconcile.run(locked: true)
            return names.count
        } ?? 0
        print(ended == 0 ? "Nothing to stop." : "Ended \(ended) hold\(ended == 1 ? "" : "s").")
        return 0
    }

    /// `awake run -- <command>`: holds a lease while the command runs and returns its exit code.
    static func run(_ args: [String]) -> Int32 {
        let argv = args.first == "--" ? Array(args.dropFirst()) : args
        guard let program = argv.first else { return fail(usage) }
        let me = getpid()
        let name = "run-\(me)"
        let lease = Lease(pid: me, command: URL(fileURLWithPath: program).lastPathComponent,
                          started: Proc.info(me)?.started ?? Date().timeIntervalSince1970)
        _ = Store.withLock {
            Store.setLease(name, lease)
            Reconcile.run(locked: true)
        }

        // Ctrl-C reaches the command straight from the terminal, so awake ignores it and waits for the
        // command to finish. TERM and HUP sent to awake itself are passed on.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil]
        var child: pid_t = 0
        let spawned = posix_spawnp(&child, program, nil, &attr, cArgs, cEnv)
        posix_spawnattr_destroy(&attr)
        (cArgs + cEnv).forEach { free($0) }

        var code: Int32 = 127
        if spawned == 0 {
            let pid = child
            let forwarders = [SIGTERM, SIGHUP].map { sig in
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler { kill(pid, sig) }
                source.resume()
                return source
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            forwarders.forEach { $0.cancel() }
            code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        } else {
            FileHandle.standardError.write(Data("awake: \(program): \(String(cString: strerror(spawned)))\n".utf8))
        }

        _ = Store.withLock {
            Store.removeLease(name)
            Reconcile.run(locked: true)
        }
        return code
    }

    /// `awake status`
    static func status() -> Int32 {
        let s = Snapshot.take()
        let d = s.decision, now = s.inputs.now
        var rows: [(String, String)] = [
            ("mode", modeName(d.mode)),
            ("switch", s.flag ? "on: closing the lid keeps the Mac running" : "off: closing the lid puts it to sleep"),
            ("lid", s.lidClosed ? "closed" : "open"),
        ]
        if let b = s.inputs.battery {
            var text = "\(b.level) %, " + (b.charging ? "charging" : b.external ? "on power, not charging" : "on battery")
            if let t = b.temperature { text += String(format: ", %.1f °C", t) }
            rows.append(("battery", text))
        }
        rows.append(("thermal", "\(s.inputs.thermal)"))
        let energy = System.batteryEnergyMode().map(Reconcile.energyName) ?? "unknown"
        rows.append(("energy", "on battery: \(energy)" + (s.savedEnergy.map { ", set by awake, \(Reconcile.energyName($0)) comes back" } ?? "")))
        rows.append(("guards", d.pause.map { "paused: \($0)" } ?? "none"))
        if let error = s.status?.error { rows.append(("error", error)) }
        if d.holds.isEmpty {
            rows.append(("holds", "none"))
        } else {
            for (i, hold) in d.holds.enumerated() {
                rows.append((i == 0 ? "holds" : "", Format.label(hold, now: now)))
            }
        }
        if s.flag != d.awake {
            rows.append(("note", "the switch differs from awake's decision; the next reconcile fixes it"))
        }
        for (key, value) in rows {
            print(key.padding(toLength: 9, withPad: " ", startingAt: 0) + value)
        }
        return 0
    }

    static func modeName(_ mode: Mode) -> String {
        switch mode {
        case .off: "Off"
        case .auto: "While agents work"
        case .on: "On"
        }
    }

    private static func report(_ status: Status?) {
        guard let status else {
            FileHandle.standardError.write(Data("awake: the state is locked; launchd applies this within 30 seconds\n".utf8))
            return
        }
        if let error = status.error {
            FileHandle.standardError.write(Data("awake: \(error)\n".utf8))
        } else if let pause = status.pause {
            print("Paused: \(pause).")
        }
    }

    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        return 64
    }
}
