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
        #expect(points.map(\.alone) == [true, true, true])
        let thermal = ActivityMetric.thermal.points(Array(samples.prefix(3)))
        #expect(thermal.map(\.segment) == [0, 0, 0])
        #expect(thermal.map(\.alone) == [false, false, false])
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

    @Test func aWriteUnderAMinuteOldSkipsReadingTheHistory() throws {
        try withHistory { file in
            let now = Date().timeIntervalSince1970
            try ActivityHistory.record(sample(now), at: file)
            // Unreadable content shows whether a record read the file: reading it would replace it.
            try Data("not json".utf8).write(to: file)
            let unread = try Data(contentsOf: file)
            try ActivityHistory.record(sample(now + 30), at: file)
            #expect(try Data(contentsOf: file) == unread)
            try ActivityHistory.record(sample(now + 61), at: file)
            #expect(ActivityHistory.load(at: file).map(\.timestamp) == [now + 61])
        }
    }

    @Test func historyReloadsOnlyAfterTheFileChanges() throws {
        try withHistory { file in
            #expect(ActivityHistory.loadIfChanged(since: nil, at: file) == nil)
            try ActivityHistory.record(sample(1000), at: file)
            let first = try #require(ActivityHistory.loadIfChanged(since: nil, at: file))
            #expect(first.samples.map(\.timestamp) == [1000])
            #expect(ActivityHistory.loadIfChanged(since: first.stamp, at: file) == nil)
            try ActivityHistory.record(sample(1060), at: file)
            let second = try #require(ActivityHistory.loadIfChanged(since: first.stamp, at: file))
            #expect(second.samples.map(\.timestamp) == [1000, 1060])
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

    @Test func aWeekDrawsAFewHundredPointsAndKeepsGapsAndSpikes() {
        var week = (0..<10_080).map { sample(Double($0) * 60, battery: 100 - $0 / 120) }
        week[5000].thermal = 2
        week.removeSubrange(7000..<7100)
        // A lone critical reading between gaps, as when the Mac wakes briefly with the lid closed.
        week.removeSubrange(8000..<8010)
        week.removeSubrange(8001..<8011)
        week[8000].thermal = 3
        let bucket = ActivityRange.week.bucket
        let thermal = ActivityMetric.thermal.points(week, bucket: bucket)
        #expect(thermal.count <= 604)
        #expect(thermal.contains { $0.value == 2 })
        #expect(Set(thermal.map(\.segment)) == [0, 1, 2, 3])
        #expect(thermal.filter(\.alone).map(\.value) == [3])
        let battery = ActivityMetric.battery.points(week, bucket: bucket)
        #expect(battery.last?.value == 100 - Double(10_079 / 120))
        #expect(ActivityMetric.battery.points(Array(week.prefix(60)), bucket: ActivityRange.hour.bucket).count == 60)
    }

    @Test func timeRangesIncludeOnlyRealSamplesWithinTheRequestedWindow() {
        let samples = [sample(0), sample(3600), sample(7200)]
        #expect(ActivityRange.hour.samples(samples, now: 7200).map(\.timestamp) == [3600, 7200])
        #expect(ActivityRange.day.samples(samples, now: 7200).count == 3)
    }
}
