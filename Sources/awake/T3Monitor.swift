import Foundation
import SQLite3

/// T3 Code 0.0.45 has no configurable turn hooks. Observe its local session projection read-only;
/// provider_session_runtime is deliberately ignored because it can remain running after a failure.
enum T3Monitor {
    static let base = (ProcessInfo.processInfo.environment["T3CODE_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".t3")).appending(path: "userdata")

    struct Session: Equatable, Sendable {
        var id: String
        var project: String
        var started: Double
        var pid: Int32
    }

    struct State: Sendable {
        var sessions: [Session] = []
        var serverRunning = false
        var problem: String? = nil

        var summary: String {
            if problem != nil { return "Monitoring unavailable" }
            if !serverRunning { return "Not running" }
            return sessions.isEmpty ? "No active turns" : "\(sessions.count) active turn\(sessions.count == 1 ? "" : "s")"
        }
    }

    private struct Runtime: Decodable { var pid: Int32; var startedAt: String }

    static func server(base: URL = base) -> Proc.Info? {
        guard let data = try? Data(contentsOf: base.appending(path: "server-runtime.json")),
              let runtime = try? JSONDecoder().decode(Runtime.self, from: data), runtime.pid > 0,
              let started = timestamp(runtime.startedAt), let process = Proc.info(runtime.pid),
              abs(process.started - started) < 2 else { return nil }
        return process
    }

    static func read(base: URL = base) -> State {
        guard let server = server(base: base) else { return State() }
        var database: OpaquePointer?
        guard sqlite3_open_v2(base.appending(path: "state.sqlite").path, &database,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return State(serverRunning: true, problem: "T3's local session state could not be read.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        let query = """
            SELECT s.thread_id, p.workspace_root, t.started_at
            FROM projection_thread_sessions s
            JOIN projection_threads h ON h.thread_id = s.thread_id
            JOIN projection_projects p ON p.project_id = h.project_id
            JOIN projection_turns t ON t.thread_id = s.thread_id AND t.turn_id = s.active_turn_id
            WHERE s.status = 'running' AND s.last_error IS NULL
              AND t.state = 'running' AND t.completed_at IS NULL
              AND h.deleted_at IS NULL AND p.deleted_at IS NULL
              AND h.pending_approval_count = 0 AND h.pending_user_input_count = 0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return State(serverRunning: true, problem: "This T3 session format is not supported.")
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        var sessions: [Session] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let id = text(0), !id.isEmpty, let root = text(1), let time = text(2), let started = timestamp(time) {
                sessions.append(Session(id: id, project: URL(fileURLWithPath: root).lastPathComponent,
                                        started: started, pid: server.pid))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            return State(serverRunning: true, problem: "T3's local session state is busy or unavailable.")
        }
        return State(sessions: sessions, serverRunning: true)
    }

    /// Refresh only Awake's T3 leases. Completion, errors and a stopped server enter the same grace
    /// period as Claude/Codex hooks; a long-running turn is renewed even during quiet model thinking.
    static func changes(sessions: [Session], existing: [(name: String, lease: Lease)], now: Double)
        -> [(name: String, lease: Lease)] {
        let names = Set(sessions.map { Store.leaseName(agent: "t3", session: $0.id) })
        var edits = sessions.map { session in
            (name: Store.leaseName(agent: "t3", session: session.id),
             lease: Lease(agent: "t3", sessionId: session.id, pid: session.pid, project: session.project,
                          started: session.started, lastSeen: now))
        }
        for (name, lease) in existing where name.hasPrefix("t3-") && !names.contains(name) && lease.isRunning {
            var ended = lease
            ended.endedAt = now
            edits.append((name, ended))
        }
        return edits
    }

    /// Called under Store's lock, alongside queued hook events.
    static func synchronize(now: Double) {
        let edits = changes(sessions: read().sessions, existing: Store.leases(), now: now)
        for (name, lease) in edits where lease != Store.lease(name) { Store.setLease(name, lease) }
    }

    private static func timestamp(_ text: String) -> Double? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date.timeIntervalSince1970 }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)?.timeIntervalSince1970
    }
}
