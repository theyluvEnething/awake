import Foundation

/// What the last reconcile decided and did, for the menu and the next reconcile.
struct Status: Codable, Equatable, Sendable {
    var awake: Bool
    var flag: Bool
    var pause: String? = nil
    var error: String? = nil
    var guards = Guards()
    /// When setting the flag or the energy mode last failed, so a missing sudo rule is retried once a
    /// minute, not per hook. Each has its own time, so one failing doesn't hold up the other.
    var flagFailedAt: Double? = nil
    var energyFailedAt: Double? = nil
    /// When the last lid-closed line went to the log.
    var loggedAt: Double? = nil
}

/// ~/Library/Application Support/awake: mode, leases/, events/, saved energy mode, status, release, lock.
/// Every file is small JSON, written to a temporary file and renamed into place.
enum Store {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/awake")
    static let leasesDir = dir.appending(path: "leases")
    static let eventsDir = dir.appending(path: "events")
    static let logFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/awake.log")

    private struct SavedEnergy: Codable { var battery: Int }
    private struct Release: Codable { var until: Double; var boot: String? }

    // MARK: Files

    static func mode() -> ModeState? { read(ModeState.self, "mode") }

    /// Sets a mode. On remembers the mode it replaced and the boot it belongs to.
    static func setMode(_ mode: Mode) {
        write(Policy.setting(mode, from: self.mode(), boot: System.bootSession()), "mode")
    }

    /// Ends On, as logout does, and returns to the mode On replaced.
    static func endOn() {
        if let state = mode(), state.mode == .on {
            write(ModeState(mode: state.base ?? .off), "mode")
        }
    }

    static func status() -> Status? { read(Status.self, "status") }
    static func setStatus(_ status: Status) { write(status, "status") }

    static func savedEnergy() -> Int? { read(SavedEnergy.self, "energy")?.battery }
    static func saveEnergy(_ mode: Int) { write(SavedEnergy(battery: mode), "energy") }
    static func forgetEnergy() { remove(dir.appending(path: "energy")) }

    /// Until when, and in which boot, Sleep Now or logout keep the switch off.
    static func release() -> (until: Double, boot: String?)? { read(Release.self, "release").map { ($0.until, $0.boot) } }
    static func release(until: Double) { write(Release(until: until, boot: System.bootSession()), "release") }
    static func clearRelease() { remove(dir.appending(path: "release")) }

    // MARK: Leases

    static func leases() -> [(name: String, lease: Lease)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: leasesDir.path)) ?? []
        return names.compactMap { name in
            guard LeaseKind(fileName: name) != nil, let lease = lease(name) else { return nil }
            return (name, lease)
        }
    }

    static func lease(_ name: String) -> Lease? { read(Lease.self, at: leasesDir.appending(path: name)) }
    static func setLease(_ name: String, _ lease: Lease) { write(lease, at: leasesDir.appending(path: name)) }
    static func removeLease(_ name: String) { remove(leasesDir.appending(path: name)) }

    /// Hook events wait in events/ for the next reconcile, which applies them under the lock.
    static func queue(_ event: QueuedEvent) {
        write(event, at: eventsDir.appending(path: "\(event.lease).\(getpid()).\(UInt64(event.stamp * 1000))"))
    }

    static func queuedEvents() -> [(file: String, event: QueuedEvent)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: eventsDir.path)) ?? []
        return names.compactMap { name in
            guard LeaseKind(fileName: name) != nil,
                  let event = read(QueuedEvent.self, at: eventsDir.appending(path: name)) else { return nil }
            return (name, event)
        }
    }

    static func removeEvent(_ file: String) { remove(eventsDir.appending(path: file)) }

    /// "claude-<session>", with anything that isn't a plain ASCII letter, digit, - or _ replaced.
    static func leaseName(agent: String, session: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return agent + "-" + String(session.prefix(120).map { allowed.contains($0) ? $0 : "_" })
    }

    // MARK: Lock

    /// Takes the state lock, waiting up to `timeout` seconds. Pass the result to `unlock`.
    static func lock(timeout: Double) -> Int32? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appending(path: "lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                close(fd)
                return nil
            }
            usleep(5_000)
        }
        return fd
    }

    static func unlock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    static func withLock<T>(timeout: Double = 5, _ body: () -> T) -> T? {
        guard let fd = lock(timeout: timeout) else { return nil }
        defer { unlock(fd) }
        return body()
    }

    // MARK: Log

    /// One line per change, in ~/Library/Logs/awake.log. Past 256 KB only the newest half is kept.
    /// Called under the lock.
    static func log(_ text: String) {
        let path = logFile.path
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 256_000,
           let data = FileManager.default.contents(atPath: path) {
            let tail = data.suffix(128_000)
            let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? tail.startIndex
            try? Data(tail[start...]).write(to: logFile, options: .atomic)
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data("\(stamp.string(from: Date()))  \(text)\n".utf8)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    // MARK: JSON

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        read(type, at: dir.appending(path: name))
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        write(value, at: dir.appending(path: name))
    }

    private static func write<T: Encodable>(_ value: T, at url: URL) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
