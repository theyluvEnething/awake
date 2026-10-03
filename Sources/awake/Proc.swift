import Darwin

/// Process facts read from the kernel with sysctl, without spawning anything.
enum Proc {
    struct Info {
        let pid: pid_t
        let ppid: pid_t
        let name: String
        /// Seconds since 1970 at which the process was created.
        let started: Double
    }

    static func info(_ pid: pid_t) -> Info? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = kp.kp_proc.p_un.__p_starttime
        return Info(pid: pid, ppid: kp.kp_eproc.e_ppid, name: name,
                    started: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// Ancestors of this process, nearest first, stopping before launchd.
    static func ancestors(limit: Int = 32) -> [Info] {
        var chain: [Info] = []
        var pid = getppid()
        while pid > 1, chain.count < limit, let p = info(pid) {
            chain.append(p)
            pid = p.ppid
        }
        return chain
    }
}
