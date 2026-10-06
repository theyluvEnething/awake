import AppKit
import Charts
import SwiftUI

struct ActivityView: View {
    let model: AwakeModel
    let expanded: Bool
    @State private var range = ActivityRange.hour
    @State private var selectedTime: Date?

    private var samples: [ActivitySample] {
        range.samples(model.samples, now: model.snapshot.inputs.now)
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
                ForEach(ActivityMetric.allCases) { metric in
                    MetricChart(metric: metric, samples: samples, selected: selected, selectedTime: $selectedTime,
                                range: range, now: model.snapshot.inputs.now, expanded: expanded)
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

private struct MetricChart: View {
    let metric: ActivityMetric
    let samples: [ActivitySample]
    let selected: ActivitySample?
    @Binding var selectedTime: Date?
    let range: ActivityRange
    let now: Double
    let expanded: Bool

    private var points: [ActivityMetric.Point] { metric.points(samples) }
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
        case .temperature: min(20, floor(points.map(\.value).min() ?? 20) - 2)...max(45, ceil(points.map(\.value).max() ?? 45) + 2)
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
            if expanded, let minimum = points.map(\.value).min(), let maximum = points.map(\.value).max() {
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
                PointMark(x: .value("Time", point.sample.date), y: .value(metric.rawValue, point.value))
                    .foregroundStyle(color).symbolSize(8)
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
        .chartXAxis {
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let frame = proxy.plotFrame {
                            let plot = geometry[frame]
                            if plot.contains(location) { selectedTime = proxy.value(atX: location.x - plot.minX) }
                        }
                    case .ended: selectedTime = nil
                    }
                }
            }
        }
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
