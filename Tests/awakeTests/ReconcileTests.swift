import Foundation
import Testing

@Suite struct ReconcileTests {
    /// Execute the production reconciler with controlled external state. This avoids real power
    /// changes and keeps the app free of test-only dependency injection.
    @Test func delayedReleasePreservesSleepIntent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/awake")
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appending(path: name + ".swift"), encoding: .utf8)
        }
        let store = try source("Store")
        let start = try #require(store.range(of: "struct Status:"))
        let end = try #require(store.range(of: "/// ~/Library"))
        let production = try [source("Policy"), source("Format"), String(store[start.lowerBound..<end.lowerBound]),
                              source("Reconcile")].joined(separator: "\n")
        let fixture = #"""
        enum System {
            static var flag = true, closed = true, immediate = false
            static var problem: String? = nil
            static var calls = 0, sleeps = 0
            static func rootDomain() -> (sleepDisabled: Bool, lidClosed: Bool) { (flag, closed) }
            static func setSleepDisabled(_ value: Bool) -> String? {
                calls += 1
                if immediate && problem == nil { flag = value }
                return problem
            }
            static func sleepNow() { sleeps += 1 }
            static func batteryEnergyMode() -> Int? { nil }
            static func setBatteryEnergyMode(_ value: Int) -> String? { nil }
            static func bootSession() -> String { "boot" }
            static func battery() -> Battery? { nil }
            static func thermal() -> Thermal { .nominal }
        }
        enum Proc {
            struct Info { var name: String; var started: Double; var pid: Int32 = 0 }
            static func info(_ pid: Int32) -> Info? { nil }
        }
        enum T3Monitor {
            static func server() -> Proc.Info? { nil }
            static func synchronize(now: Double) {}
        }
        struct ActivitySample {
            static func take(_ snapshot: Snapshot, flag: Bool) -> ActivitySample { ActivitySample() }
        }
        enum ActivityHistory {
            static func record(_ sample: ActivitySample) throws {}
        }
        enum Store {
            static var saved: Status? = nil
            static var selected = ModeState(mode: .off)
            static var logs: [String] = []
            static func status() -> Status? { saved }
            static func setStatus(_ value: Status) {
                saved = try! JSONDecoder().decode(Status.self, from: JSONEncoder().encode(value))
            }
            static func mode() -> ModeState? { selected }
            static func keepDisplayOn() -> Bool { false }
            static func release() -> (until: Double, boot: String?)? { nil }
            static func leases() -> [(name: String, lease: Lease)] { [] }
            static func lease(_ name: String) -> Lease? { nil }
            static func queuedEvents() -> [(String, QueuedEvent)] { [] }
            static func setLease(_ name: String, _ lease: Lease?) {}
            static func removeEvent(_ name: String) {}
            static func removeLease(_ name: String) {}
            static func clearRelease() {}
            static func savedEnergy() -> Int? { nil }
            static func saveEnergy(_ value: Int) {}
            static func forgetEnergy() {}
            static func log(_ text: String) { logs.append(text) }
            static func withLock<T>(_ action: () -> T) -> T? { action() }
        }
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        func reset() {
            System.flag = true; System.closed = true; System.immediate = false
            System.problem = nil; System.calls = 0; System.sleeps = 0
            Store.selected = ModeState(mode: .off)
            Store.saved = Status(awake: true, flag: true, loggedAt: Date().timeIntervalSince1970)
            Store.logs = []
        }

        reset()
        System.immediate = true
        Reconcile.run(); Reconcile.run()
        check("immediate release sleeps once", System.sleeps == 1 && System.calls == 1)

        reset()
        Reconcile.run()
        check("successful reply alone cannot request sleep", System.sleeps == 0)
        System.flag = false
        Reconcile.run(); Reconcile.run()
        check("delayed release sleeps once", System.sleeps == 1 && System.calls == 1)
        check("delayed release is logged", Store.logs.contains { $0.hasPrefix("lid sleep on") })

        reset()
        System.problem = "helper failed"
        Reconcile.run(); Reconcile.run()
        check("unchanged flag after failure cannot sleep", System.sleeps == 0 && System.calls == 1)
        System.flag = false
        Reconcile.run(); Reconcile.run()
        check("lost reply followed by observed release sleeps once", System.sleeps == 1 && System.calls == 1)

        reset()
        Reconcile.run()
        Store.selected = ModeState(mode: .on, base: .off, boot: "boot")
        System.flag = false; System.immediate = true
        Reconcile.run()
        check("renewed awake decision cancels sleep", System.sleeps == 0 && System.flag)

        reset()
        Reconcile.run(sleepAfterRelease: false)
        Reconcile.run()
        System.flag = false
        Reconcile.run(); Reconcile.run()
        check("suppressed release stays suppressed across retries", System.sleeps == 0)
        System.flag = true; System.immediate = true
        Reconcile.run()
        check("suppression ends after that release", System.sleeps == 1)

        reset()
        Reconcile.run()
        Reconcile.run(sleepAfterRelease: false)
        System.flag = false
        Reconcile.run()
        check("explicit suppression cancels pending sleep", System.sleeps == 0)

        reset()
        Reconcile.run()
        System.flag = false; System.closed = false
        Reconcile.run()
        System.closed = true
        Reconcile.run()
        check("opening the lid clears pending sleep", System.sleeps == 0)
        exit(failures == 0 ? 0 : 1)
        """#
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((production + "\n" + fixture).utf8))
        try input.fileHandleForWriting.close()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(result)")
    }
}
