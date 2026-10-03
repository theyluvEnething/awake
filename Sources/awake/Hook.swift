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

        // Hooks run concurrently, so the event is queued and the reconcile applies it to the lease
        // under the lock. All but Codex's SessionEnd run async, so waiting up to 5 seconds for the
        // lock doesn't hold up the agent. If it stays busy, the next reconcile applies the event.
        Store.queue(QueuedEvent(lease: Store.leaseName(agent: agent, session: session), event: event, stamp: stamp,
                                agent: agent, sessionId: session, pid: owner, project: project,
                                now: Date().timeIntervalSince1970))
        Reconcile.run()
    }
}
