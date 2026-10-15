import AppKit
import Charts
import SwiftUI

struct ActivityView: View {
    let model: AwakeModel
    let expanded: Bool
    @State private var range = ActivityRange.hour
    @State private var selectedTime: Date?

    /// The snapshot changes every few seconds; samples arrive once a minute. Ending the range on the
    /// next whole minute keeps the charts unchanged, and undrawn, between samples.
    private var now: Double { (model.snapshot.inputs.now / 60).rounded(.up) * 60 }

    private var samples: [ActivitySample] {
        range.samples(model.samples, now: now)
    }

    private var selected: ActivitySample? {
        guard let selectedTime else { return samples.last }
        let time = selectedTime.timeIntervalSince1970
        let nearest = samples.min { abs($0.timestamp - time) < abs($1.timestamp - time) }
        return nearest.flatMap { abs($0.timestamp - time) <= 120 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Activity").font(.system(size: expanded ? 20 : 15, weight: .semibold))
                Spacer()
                if expanded {
                    rangePicker.pickerStyle(.segmented).frame(width: 360)
                } else {
                    rangePicker.pickerStyle(.menu).fixedSize()
                }
            }
            HStack {
                Text(selected.map { "Recorded \($0.date.formatted(date: .abbreviated, time: .standard))" }
                    ?? (samples.isEmpty ? "History starts when Awake is running." : "No sample at this time."))
                Spacer()
                if let selected {
                    Text(selected.awake ? "Lid sleep off" : "Lid sleep on")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryInk)

            Panel {
                AgentChart(samples: samples, selected: selected, selectedTime: selectedTime, range: range, now: now,
                           expanded: expanded, t3: model.t3.summary, t3Problem: model.t3.problem,
                           select: { selectedTime = $0 })
                    .equatable()
                ForEach(ActivityMetric.allCases) { metric in
                    MetricChart(metric: metric, samples: samples, selected: selected, selectedTime: selectedTime,
                                range: range, now: now, expanded: expanded, select: { selectedTime = $0 })
                        .equatable()
                }
            }

            HStack(alignment: .top) {
                Text("One sample a minute. Seven days kept on this Mac. Gaps mean no data was recorded.")
                Spacer()
                if expanded {
                    Button("Open text log", systemImage: "doc.text") { NSWorkspace.shared.open(Store.logFile) }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryInk)
            if expanded {
                Text("Move over a graph to inspect a recorded moment.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondaryInk)
            }
        }
        .foregroundStyle(Palette.ink)
    }

    private var rangePicker: some View {
        Picker("History range", selection: $range) {
            ForEach(ActivityRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .onChange(of: range) { selectedTime = nil }
    }
}

/// Equatable without `select`, so SwiftUI redraws a chart only when what it shows changes.
private struct MetricChart: View, Equatable {
    let metric: ActivityMetric
    let samples: [ActivitySample]
    let selected: ActivitySample?
    let selectedTime: Date?
    let range: ActivityRange
    let now: Double
    let expanded: Bool
    let select: (Date?) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.metric == b.metric && a.selected == b.selected && a.selectedTime == b.selectedTime && a.range == b.range
            && a.now == b.now && a.expanded == b.expanded && a.samples == b.samples
    }

    private var points: [ActivityMetric.Point] { metric.points(samples, bucket: range.bucket) }
    /// Every recorded value, for the minimum and maximum, which drawn points may skip.
    private var values: [Double] { samples.compactMap(metric.value) }
    private var color: Color {
        switch metric {
        case .battery: .green
        case .temperature: .orange
        case .thermal: .cyan
        }
    }
    private var domain: ClosedRange<Double> {
        switch metric {
        case .battery: 0...100
        case .temperature: min(20, floor(values.min() ?? 20) - 2)...max(45, ceil(values.max() ?? 45) + 2)
        case .thermal: -0.2...3.2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric.rawValue).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(valueText(selected.flatMap(metric.value))).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            chart.frame(height: expanded ? 130 : 86)
            if expanded, let minimum = values.min(), let maximum = values.max() {
                Text("Min \(valueText(minimum))   Max \(valueText(maximum))")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondaryInk)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.sample.date), y: .value(metric.rawValue, point.value),
                         series: .value("Recording", point.segment))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(metric == .thermal ? .stepEnd : .linear)
                if range.marksSamples || point.alone {
                    PointMark(x: .value("Time", point.sample.date), y: .value(metric.rawValue, point.value))
                        .foregroundStyle(color).symbolSize(8)
                }
            }
            if let selectedTime {
                RuleMark(x: .value("Selected time", selectedTime))
                    .foregroundStyle(Palette.secondaryInk.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: Date(timeIntervalSince1970: now - range.seconds)...Date(timeIntervalSince1970: now))
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: metric == .thermal ? [0.0, 1, 2, 3] : [domain.lowerBound, (domain.lowerBound + domain.upperBound) / 2, domain.upperBound]) { axis in
                AxisGridLine().foregroundStyle(Palette.line)
                AxisValueLabel {
                    if let value = axis.as(Double.self) {
                        Text(axisText(value)).font(.system(size: 9)).foregroundStyle(Palette.secondaryInk)
                    }
                }
            }
        }
        .activityTimeAxis(range, expanded: expanded)
        .activityHover(select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.rawValue + " history")
        .accessibilityValue(valueText(selected.flatMap(metric.value)))
    }

    private func axisText(_ value: Double) -> String {
        switch metric {
        case .battery: "\(Int(value))%"
        case .temperature: "\(Int(value))°"
        case .thermal: Thermal(rawValue: Int(value)).map(Format.thermal) ?? "Unknown"
        }
    }

    private func valueText(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        switch metric {
        case .battery: return "\(Int(value)) %"
        case .temperature: return String(format: "%.1f °C", value)
        case .thermal: return Thermal(rawValue: Int(value)).map(Format.thermal) ?? "Unknown"
        }
    }
}

/// Agent turns active each minute, stacked in one colour per agent. The legend names each agent and
/// gives its count at the selected moment, so identity never rests on colour alone.
private struct AgentChart: View, Equatable {
    let samples: [ActivitySample]
    let selected: ActivitySample?
    let selectedTime: Date?
    let range: ActivityRange
    let now: Double
    let expanded: Bool
    let t3: String
    let t3Problem: String?
    let select: (Date?) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.selected == b.selected && a.selectedTime == b.selectedTime && a.range == b.range && a.now == b.now
            && a.expanded == b.expanded && a.t3 == b.t3 && a.t3Problem == b.t3Problem && a.samples == b.samples
    }

    private struct Segment: Identifiable {
        var bar: AgentBar
        var kind: AgentKind
        var from: Int
        var to: Int
        var id: String { "\(bar.start)-\(kind.rawValue)" }
    }

    private func segments(_ bars: [AgentBar]) -> [Segment] {
        bars.flatMap { bar in
            var top = 0
            return AgentKind.allCases.compactMap { kind -> Segment? in
                let count = bar.counts[kind] ?? 0
                guard count > 0 else { return nil }
                defer { top += count }
                return Segment(bar: bar, kind: kind, from: top, to: top + count)
            }
        }
    }

    var body: some View {
        let bars = AgentBar.bars(samples, bucket: range.bucket)
        let top = max(2, bars.map(\.total).max() ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active agents").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(totalText).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            HStack(spacing: 14) {
                ForEach(AgentKind.allCases) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.agent(kind)).frame(width: 8, height: 8)
                        Text(kind.name + (selected?.agents.map { " \($0[kind.rawValue] ?? 0)" } ?? ""))
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryInk)
            chart(segments(bars), top: top).frame(height: expanded ? 110 : 70)
            HStack {
                Text("T3 Code")
                Spacer()
                Text(t3)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryInk)
            if let t3Problem {
                Text(t3Problem).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private var totalText: String {
        guard let agents = selected?.agents else { return "Unavailable" }
        let total = agents.values.reduce(0, +)
        return total == 0 ? "None" : "\(total) active"
    }

    private func chart(_ segments: [Segment], top: Int) -> some View {
        // One-minute bars are wide enough to keep a gap between them; longer ranges draw them touching.
        // Stacked segments keep about two points between them, so neighbouring colours stay apart.
        let inset = range == .hour ? 0.12 : 0
        let gap = Double(top) / (expanded ? 110 : 70)
        return Chart {
            ForEach(segments) { s in
                let width = s.bar.end - s.bar.start
                RectangleMark(xStart: .value("Start", Date(timeIntervalSince1970: s.bar.start + width * inset)),
                              xEnd: .value("End", Date(timeIntervalSince1970: s.bar.end - width * inset)),
                              yStart: .value("From", Double(s.from) + (s.from > 0 ? gap : 0)),
                              yEnd: .value("To", Double(s.to) - gap))
                    .foregroundStyle(Palette.agent(s.kind))
            }
            if let selectedTime {
                RuleMark(x: .value("Selected time", selectedTime))
                    .foregroundStyle(Palette.secondaryInk.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: Date(timeIntervalSince1970: now - range.seconds)...Date(timeIntervalSince1970: now))
        .chartYScale(domain: 0...Double(top))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, Double(top)]) { axis in
                AxisGridLine().foregroundStyle(Palette.line)
                AxisValueLabel {
                    if let value = axis.as(Double.self) {
                        Text("\(Int(value))").font(.system(size: 9)).foregroundStyle(Palette.secondaryInk)
                    }
                }
            }
        }
        .activityTimeAxis(range, expanded: expanded)
        .activityHover(select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Active agents history")
        .accessibilityValue(AgentKind.allCases.map { "\($0.name) \(selected?.agents?[$0.rawValue] ?? 0)" }
            .joined(separator: ", "))
    }
}

private extension View {
    /// Times under the graph: hours and minutes, or days for the week.
    func activityTimeAxis(_ range: ActivityRange, expanded: Bool) -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: expanded ? 5 : 3)) { axis in
                AxisValueLabel(centered: false,
                               anchor: axis.index == 0 ? .topLeading : axis.index == axis.count - 1 ? .topTrailing : .top,
                               collisionResolution: .greedy) {
                    if let date = axis.as(Date.self) {
                        Text(date.formatted(range == .week ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()))
                            .font(.system(size: 9)).foregroundStyle(Palette.secondaryInk)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    /// Moving over a graph selects the moment under the pointer in every graph.
    func activityHover(_ select: @escaping (Date?) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let frame = proxy.plotFrame {
                            let plot = geometry[frame]
                            if plot.contains(location) { select(proxy.value(atX: location.x - plot.minX)) }
                        }
                    case .ended: select(nil)
                    }
                }
            }
        }
    }
}
