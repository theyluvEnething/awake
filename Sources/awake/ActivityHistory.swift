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

    var id: Double { timestamp }
    var date: Date { Date(timeIntervalSince1970: timestamp) }

    static func take(_ snapshot: Snapshot, flag: Bool) -> ActivitySample {
        ActivitySample(timestamp: snapshot.inputs.now, batteryLevel: snapshot.inputs.battery?.level,
                       temperature: snapshot.inputs.battery?.temperature, thermal: snapshot.inputs.thermal.rawValue,
                       awake: flag, lidClosed: snapshot.lidClosed, externalPower: snapshot.inputs.battery?.external)
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
}

enum ActivityMetric: String, CaseIterable, Identifiable {
    case battery = "Battery", temperature = "Battery temperature", thermal = "Thermal state"
    var id: Self { self }

    struct Point: Identifiable {
        var sample: ActivitySample
        var value: Double
        var segment: Int
        var id: Double { sample.timestamp }
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
        return points
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

    static func record(_ sample: ActivitySample, at file: URL = file) throws {
        guard sample.timestamp.isFinite else { return }
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
