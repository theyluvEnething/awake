import Foundation
import Testing
@testable import awake

private func withHistory(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "awake-history-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder.appending(path: "activity.json"))
}

private func sample(_ time: Double, battery: Int? = 80, temperature: Double? = 30) -> ActivitySample {
    ActivitySample(timestamp: time, batteryLevel: battery, temperature: temperature, thermal: 0,
                   awake: true, lidClosed: false, externalPower: true)
}

struct ActivityHistoryTests {
    @Test func chartsDoNotBridgeSleepGapsOrMissingSensors() {
        let samples = [sample(1000), sample(1060, battery: nil), sample(1120), sample(1800)]
        let points = ActivityMetric.battery.points(samples)
        #expect(points.map { $0.sample.timestamp } == [1000, 1120, 1800])
        #expect(points.map(\.segment) == [0, 1, 2])
        #expect(ActivityMetric.thermal.points(Array(samples.prefix(3))).map(\.segment) == [0, 0, 0])
    }

    @Test func samplesPersistAcrossReadsAndDoNotDuplicateWithinAMinute() throws {
        try withHistory { file in
            try ActivityHistory.record(sample(1000), at: file)
            let before = try Data(contentsOf: file)
            try ActivityHistory.record(sample(1059), at: file)
            #expect(try Data(contentsOf: file) == before)
            try ActivityHistory.record(sample(1060, battery: 79), at: file)
            let restored = ActivityHistory.load(at: file)
            #expect(restored.map(\.timestamp) == [1000, 1060])
            #expect(restored.map(\.batteryLevel) == [80, 79])
        }
    }

    @Test func oldAndFutureSamplesArePrunedInsteadOfInventingHistory() throws {
        try withHistory { file in
            let previous = [sample(1), sample(604_800), sample(900_000)]
            try JSONEncoder().encode(previous).write(to: file)
            try ActivityHistory.record(sample(604_801), at: file)
            #expect(ActivityHistory.load(at: file).map(\.timestamp) == [604_800])
            try ActivityHistory.record(sample(604_860), at: file)
            #expect(ActivityHistory.load(at: file).map(\.timestamp) == [604_800, 604_860])
        }
    }

    @Test func absentBatterySensorsRemainAbsentAndCorruptHistoryRecovers() throws {
        try withHistory { file in
            try Data("incomplete json".utf8).write(to: file)
            #expect(ActivityHistory.load(at: file).isEmpty)
            try ActivityHistory.record(sample(1000, battery: nil, temperature: nil), at: file)
            let restored = try #require(ActivityHistory.load(at: file).first)
            #expect(restored.batteryLevel == nil)
            #expect(restored.temperature == nil)
            #expect(restored.thermal == 0)
        }
    }

    @Test func timeRangesIncludeOnlyRealSamplesWithinTheRequestedWindow() {
        let samples = [sample(0), sample(3600), sample(7200)]
        #expect(ActivityRange.hour.samples(samples, now: 7200).map(\.timestamp) == [3600, 7200])
        #expect(ActivityRange.day.samples(samples, now: 7200).count == 3)
    }
}
