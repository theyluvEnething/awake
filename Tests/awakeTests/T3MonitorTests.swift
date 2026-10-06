import Foundation
import SQLite3
import Testing
@testable import awake

private func withT3State(_ body: (URL, OpaquePointer) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "awake-t3-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let process = try #require(Proc.info(getpid()))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = formatter.string(from: Date(timeIntervalSince1970: process.started))
    let runtime = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "startedAt": stamp])
    try runtime.write(to: base.appending(path: "server-runtime.json"))
    var database: OpaquePointer?
    #expect(sqlite3_open(base.appending(path: "state.sqlite").path, &database) == SQLITE_OK)
    let db = try #require(database)
    defer { sqlite3_close(db) }
    let schema = """
        CREATE TABLE projection_projects(project_id TEXT, workspace_root TEXT, deleted_at TEXT);
        CREATE TABLE projection_threads(thread_id TEXT, project_id TEXT, deleted_at TEXT,
          pending_approval_count INTEGER DEFAULT 0, pending_user_input_count INTEGER DEFAULT 0);
        CREATE TABLE projection_thread_sessions(thread_id TEXT, status TEXT, active_turn_id TEXT, last_error TEXT);
        CREATE TABLE projection_turns(thread_id TEXT, turn_id TEXT, state TEXT, started_at TEXT, completed_at TEXT);
        INSERT INTO projection_projects VALUES ('project', '/projects/example', NULL);
        INSERT INTO projection_threads(thread_id, project_id) VALUES ('working', 'project'), ('failed', 'project'), ('idle', 'project');
        INSERT INTO projection_thread_sessions VALUES ('working', 'running', 'turn', NULL),
          ('failed', 'error', 'failed-turn', 'workspace routing discovery failed'), ('idle', 'ready', NULL, NULL);
        INSERT INTO projection_turns VALUES ('working', 'turn', 'running', '2026-10-06T07:00:00.000Z', NULL),
          ('failed', 'failed-turn', 'error', '2026-10-06T07:00:00.000Z', '2026-10-06T07:00:06.000Z');
        """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    try body(base, db)
}

struct T3MonitorTests {
    @Test func onlyAnActiveLocalTurnCountsAndTheDatabaseIsNotChanged() throws {
        try withT3State { base, _ in
            let file = base.appending(path: "state.sqlite")
            let before = try Data(contentsOf: file)
            let state = T3Monitor.read(base: base)
            #expect(state.sessions.map(\.id) == ["working"])
            #expect(state.sessions.first?.project == "example")
            #expect(state.problem == nil)
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test func completedInterruptedAndWaitingTurnsDoNotCount() throws {
        try withT3State { base, db in
            #expect(sqlite3_exec(db, "UPDATE projection_threads SET pending_user_input_count=1 WHERE thread_id='working'", nil, nil, nil) == SQLITE_OK)
            #expect(T3Monitor.read(base: base).sessions.isEmpty)
            #expect(sqlite3_exec(db, "UPDATE projection_threads SET pending_user_input_count=0, pending_approval_count=1", nil, nil, nil) == SQLITE_OK)
            #expect(T3Monitor.read(base: base).sessions.isEmpty)
            #expect(sqlite3_exec(db, "UPDATE projection_threads SET pending_approval_count=0; UPDATE projection_thread_sessions SET status='interrupted' WHERE thread_id='working'", nil, nil, nil) == SQLITE_OK)
            #expect(T3Monitor.read(base: base).sessions.isEmpty)
            #expect(sqlite3_exec(db, "UPDATE projection_thread_sessions SET status='running' WHERE thread_id='working'; UPDATE projection_turns SET state='completed', completed_at='2026-10-06T07:01:00.000Z'", nil, nil, nil) == SQLITE_OK)
            #expect(T3Monitor.read(base: base).sessions.isEmpty)
        }
    }

    @Test func deadOrReusedServerPidsCannotLeaveAnActiveHold() throws {
        try withT3State { base, _ in
            try Data("{\"pid\":-1,\"startedAt\":\"2026-10-06T07:00:00.000Z\"}".utf8).write(to: base.appending(path: "server-runtime.json"))
            #expect(T3Monitor.read(base: base).sessions.isEmpty)
            let reused = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "startedAt": "2000-01-01T00:00:00.000Z"])
            try reused.write(to: base.appending(path: "server-runtime.json"))
            #expect(T3Monitor.read(base: base).sessions.isEmpty)
        }
    }

    @Test func unavailableOrChangedSchemasFailWithoutCreatingFiles() throws {
        try withT3State { base, db in
            #expect(sqlite3_exec(db, "DROP TABLE projection_thread_sessions", nil, nil, nil) == SQLITE_OK)
            let state = T3Monitor.read(base: base)
            #expect(state.sessions.isEmpty)
            #expect(state.problem != nil)
            let missing = base.appending(path: "missing")
            #expect(T3Monitor.read(base: missing).sessions.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }

    @Test func finishingAndFailedSessionsUseTheExistingOneMinuteGrace() {
        let now = 1_791_271_200.0
        let old = Lease(agent: "t3", sessionId: "working", pid: getpid(), project: "example", started: now - 5400, lastSeen: now - 5)
        let ended = T3Monitor.changes(sessions: [], existing: [("t3-working", old)], now: now)
        #expect(ended.count == 1)
        #expect(ended.first?.lease.endedAt == now)
        let active = T3Monitor.Session(id: "working", project: "example", started: now - 5400, pid: getpid())
        let renewed = T3Monitor.changes(sessions: [active], existing: [("t3-working", old)], now: now)
        #expect(renewed.first?.lease.started == now - 5400)
        #expect(renewed.first?.lease.lastSeen == now)
        #expect(renewed.first?.lease.endedAt == nil)
        let entry = LeaseEntry(name: "t3-working", kind: .agent, lease: ended[0].lease, pidAlive: true)
        var inputs = Inputs(now: now + 59, boot: "boot", mode: ModeState(mode: .auto), leases: [entry], battery: nil,
                            thermal: .nominal, guards: Guards(), releaseUntil: nil)
        #expect(Policy.decide(inputs).awake)
        inputs.now = now + 60
        #expect(!Policy.decide(inputs).awake)
        inputs.now = now
        inputs.mode = ModeState(mode: .off)
        #expect(!Policy.decide(inputs).awake)
    }
}
