import Foundation

/// `awake hook claude|codex`: Claude Code and Codex hooks call this with the event JSON on stdin.
/// It prints nothing, because both agents can feed hook output to the model, and always exits 0.
/// Of the JSON it keeps only the event name, the session id and the folder name of cwd; never the
/// prompt.
enum Hook {
    static func run(agent: String) {
        // The hook process's own start time orders events whose hooks finish out of order.
        let stamp = Proc.info(getpid())?.started ?? Date().timeIntervalSince1970
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard agent == "claude" || agent == "codex",
              let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let event = (json["hook_event_name"] as? String).flatMap(HookEvent.init(name:)),
              let session = json["session_id"] as? String, !session.isEmpty
        else { return }

        // In the desktop apps the agent process lives for hours; it's the pid that catches a crash.
        let owner = Proc.ancestors().first { $0.name == agent }?.pid
        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let name = Store.leaseName(agent: agent, session: session)

        // Hooks run concurrently. If the lock stays busy, still record the event and leave the
        // decision to the next reconcile, at most 30 seconds away.
        let fd = Store.lock(timeout: 0.8)
        defer { if let fd { Store.unlock(fd) } }
        let old = Store.lease(name)
        let lease = Lease.applying(event, stamp: stamp, agent: agent, sessionId: session, pid: owner,
                                   project: project, to: old, now: Date().timeIntervalSince1970)
        if lease != old { Store.setLease(name, lease) }
        if fd != nil { Reconcile.run(locked: true) }
    }
}
