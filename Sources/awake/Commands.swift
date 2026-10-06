import Foundation

enum Commands {
    static let usage = """
        usage: awake set off|auto|on   choose \(Format.mode(.off)), \(Format.mode(.auto)) or \(Format.mode(.on))
               awake run -- <command>  keep the Mac running while the command runs, in any mode
               awake for 90m           keep it running for 90s, 90m, 2h or 1h30m, in any mode
               awake stop              end every run and for hold
               awake status            show what Awake sees and decides
               awake reconcile         apply the decision now (launchd runs this every 30 seconds)

        modes: off   \(Format.mode(.off)): \(Format.explain(.off))
               auto  \(Format.mode(.auto)): \(Format.explain(.auto))
               on    \(Format.mode(.on)): \(Format.explain(.on))
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

    /// `awake status`: the rows of the Settings window, plus the lid.
    static func status() -> Int32 {
        let s = Snapshot.take()
        let d = s.decision
        var rows = [
            ("Mode", Format.mode(d.mode)),
            ("Lid sleep", "\(Format.lidSleep(s.flag)): \(Format.lidEffect(s.flag))"),
            ("Lid", s.lidClosed ? "Closed" : "Open"),
        ]
        let holds = d.holds.map { Format.hold($0, now: s.inputs.now) }
        rows.append(("T3 Code", T3Monitor.read().summary))
        for (i, hold) in (holds.isEmpty ? ["None"] : holds).enumerated() {
            rows.append((i == 0 ? "Holds" : "", hold))
        }
        if let pause = d.pause { rows.append(("Paused", Format.capitalized(Format.pause(pause)))) }
        if let status = s.status, status.awake != s.flag {
            rows.append(("Warning", Format.capitalized(Format.changedOutside(flag: s.flag))))
        }
        if let error = s.status?.error { rows.append(("Error", Format.capitalized(error))) }
        if let b = s.inputs.battery { rows.append(("Battery", Format.battery(b))) }
        rows.append(("Thermal state", Format.thermal(s.inputs.thermal)))
        rows.append(("Low Power", Format.lowPower(setByAwake: s.savedEnergy != nil)))
        for (key, value) in rows {
            print(key.padding(toLength: 15, withPad: " ", startingAt: 0) + value)
        }
        return 0
    }

    private static func report(_ status: Status?) {
        guard let status else {
            FileHandle.standardError.write(Data("awake: the state is locked; launchd applies this within 30 seconds\n".utf8))
            return
        }
        if let error = status.error {
            FileHandle.standardError.write(Data("awake: \(error)\n".utf8))
        } else if let pause = Snapshot.take().decision.pause {
            print(Format.paused(pause) + ".")
        }
    }

    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        return 64
    }
}
