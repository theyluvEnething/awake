import Foundation

/// Real observations only. Missing sensors stay nil; timestamps also expose gaps during sleep.
struct ActivitySample: Codable, Equatable, Identifiable, Sendable {
    var timestamp: Double
    var batteryLevel: Int?
    var temperature: Double?
    var thermal: Int
    var awake: Bool
    var lidClosed: Bool
    var externalPower: Bool?
    /// Agent turns active during the minute, by agent; zero counts are left out. Nil in samples
    /// recorded before Awake counted them.
    var agents: [String: Int]? = nil

    var id: Double { timestamp }
    var date: Date { Date(timeIntervalSince1970: timestamp) }

    static func take(_ snapshot: Snapshot, flag: Bool) -> ActivitySample {
        ActivitySample(timestamp: snapshot.inputs.now, batteryLevel: snapshot.inputs.battery?.level,
                       temperature: snapshot.inputs.battery?.temperature, thermal: snapshot.inputs.thermal.rawValue,
                       awake: flag, lidClosed: snapshot.lidClosed, externalPower: snapshot.inputs.battery?.external,
                       agents: Policy.activeAgents(snapshot.inputs))
    }
}

/// The agents Activity graphs, in the stacking and legend order.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, t3
    var id: Self { self }
    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .t3: "T3 Code"
        }
    }
}

/// One stretch of the agents graph: the most turns each agent had active within it.
struct AgentBar: Identifiable, Equatable {
    var start: Double
    var end: Double
    var counts: [AgentKind: Int]
    var id: Double { start }
    var total: Int { counts.values.reduce(0, +) }

    /// One bar per `bucket` seconds, or per sample within a minute's range. Samples without agent
    /// counts leave a gap, as the other graphs do.
    static func bars(_ samples: [ActivitySample], bucket: Double) -> [AgentBar] {
        let width = max(bucket, 60)
        var bars: [AgentBar] = []
        for sample in samples {
            guard let agents = sample.agents else { continue }
            let start = (sample.timestamp / width).rounded(.down) * width
            var counts: [AgentKind: Int] = [:]
            for kind in AgentKind.allCases { counts[kind] = agents[kind.rawValue] ?? 0 }
            if let last = bars.last, last.start == start {
                for kind in AgentKind.allCases { bars[bars.count - 1].counts[kind] = max(last.counts[kind] ?? 0, counts[kind] ?? 0) }
            } else {
                bars.append(AgentBar(start: start, end: start + width, counts: counts))
            }
        }
        return bars
    }
}

enum ActivityRange: String, CaseIterable, Identifiable {
    case hour = "1 hour", sixHours = "6 hours", day = "24 hours", week = "7 days"
    var id: Self { self }
    var seconds: Double {
        switch self {
        case .hour: 3600
        case .sixHours: 21_600
        case .day: 86_400
        case .week: 604_800
        }
    }

    func samples(_ samples: [ActivitySample], now: Double) -> [ActivitySample] {
        samples.filter { $0.timestamp >= now - seconds && $0.timestamp <= now }
    }

    /// Seconds per drawn point: about 600 points across the range, never finer than one sample a minute.
    var bucket: Double { seconds / 600 }

    /// Dots for each sample only where they can be told apart.
    var marksSamples: Bool { self == .hour || self == .sixHours }
}

enum ActivityMetric: String, CaseIterable, Identifiable {
    case battery = "Battery", temperature = "Battery temperature", thermal = "Thermal state"
    var id: Self { self }

    struct Point: Identifiable {
        var sample: ActivitySample
        var value: Double
        var segment: Int
        /// The only point of its segment: a line can't show it, so the chart draws a dot.
        var alone = false
        var id: Double { sample.timestamp }
    }

    private static func markAlone(_ points: [Point]) -> [Point] {
        var counts: [Int: Int] = [:]
        for point in points { counts[point.segment, default: 0] += 1 }
        return points.map { point in
            var point = point
            point.alone = counts[point.segment] == 1
            return point
        }
    }

    func value(_ sample: ActivitySample) -> Double? {
        switch self {
        case .battery: sample.batteryLevel.map(Double.init)
        case .temperature: sample.temperature
        case .thermal: Double(sample.thermal)
        }
    }

    func points(_ samples: [ActivitySample]) -> [Point] {
        var segment = 0
        var last: Double?
        var points: [Point] = []
        for sample in samples {
            guard let value = value(sample) else { segment += 1; last = nil; continue }
            if let last, sample.timestamp - last > 120 { segment += 1 }
            points.append(Point(sample: sample, value: value, segment: segment))
            last = sample.timestamp
        }
        return Self.markAlone(points)
    }

    /// One point per `bucket` seconds, so a week draws a few hundred points instead of ten thousand.
    /// Temperature and thermal state keep each bucket's highest value, so spikes stay visible; battery
    /// keeps the latest. Gaps stay gaps.
    func points(_ samples: [ActivitySample], bucket: Double) -> [Point] {
        let all = points(samples)
        guard bucket > 60 else { return all }
        var kept: [Point] = []
        var key: (segment: Int, bucket: Double)?
        for point in all {
            let current = (segment: point.segment, bucket: (point.sample.timestamp / bucket).rounded(.down))
            if let key, key == current, let previous = kept.last {
                if self == .battery || point.value >= previous.value { kept[kept.count - 1] = point }
            } else {
                kept.append(point)
                key = current
            }
        }
        return Self.markAlone(kept)
    }
}

/// One sample a minute, seven days on disk, written under the same lock as power state.
/// It lives inside Awake's existing state directory, so normal uninstall removes it too.
enum ActivityHistory {
    static let file = Store.dir.appending(path: "activity.json")
    static let retention: Double = 604_800
    static let maximumCount = 10_081

    static func load(at file: URL = file) -> [ActivitySample] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size <= 4_000_000, let data = try? Data(contentsOf: file),
              let samples = try? JSONDecoder().decode([ActivitySample].self, from: data) else { return [] }
        return Array(samples.suffix(maximumCount))
    }

    /// When the history file was last written, in seconds since 1970.
    static func modified(at file: URL = file) -> Double? {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970
    }

    /// The history and its write time, or nil when the file hasn't changed since `stamp` or is missing.
    /// The menu reloads with this after each reconcile, so seven days are decoded once a minute at most.
    static func loadIfChanged(since stamp: Double?, at file: URL = file) -> (stamp: Double, samples: [ActivitySample])? {
        guard let modified = modified(at: file), modified != stamp else { return nil }
        return (modified, load(at: file))
    }

    static func record(_ sample: ActivitySample, at file: URL = file) throws {
        guard sample.timestamp.isFinite else { return }
        // Hooks, the menu and launchd reconcile every few seconds; a new sample is due once a minute.
        // Skip decoding seven days of history while the last write is under a minute old.
        if let written = modified(at: file), (0..<60).contains(sample.timestamp - written) { return }
        let previous = load(at: file)
        var samples = previous.filter { $0.timestamp > sample.timestamp - retention && $0.timestamp <= sample.timestamp }
        if sample.timestamp - (samples.last?.timestamp ?? -.infinity) >= 60 {
            samples.append(sample)
        }
        samples = Array(samples.suffix(maximumCount))
        guard samples != previous else { return }
        let data = try JSONEncoder().encode(samples)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
