import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AwakeModel {
    var snapshot: Snapshot
    var displayAwake = false
    var displayError: String?

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}

/// The settings window: the lid modes, the independent display option, and what Awake sees right now.
struct SettingsView: View {
    let model: AwakeModel
    let updates: UpdateController
    let setAwake: @MainActor @Sendable (Bool) -> Void
    let setIndefinitely: @MainActor @Sendable (Bool) -> Void
    let setKeepDisplayOn: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        let s = model.snapshot
        let d = s.decision
        VStack(alignment: .leading, spacing: 24) {
            Panel {
                Toggle(isOn: Binding(get: { d.mode != .off }, set: setAwake)) {
                    Row(Format.mode(.auto), detail: Format.sentence(Format.explain(.auto)))
                }
                Toggle(isOn: Binding(get: { d.mode == .on }, set: setIndefinitely)) {
                    Row(Format.mode(.on), detail: Format.sentence(Format.explain(.on)))
                }
                Toggle(isOn: Binding(get: { s.inputs.keepDisplayOn }, set: setKeepDisplayOn)) {
                    Row("Keep display on", detail: "Prevents the screen from dimming or turning off while idle, until you turn this off or quit Awake.")
                }
            }

            Panel("Now") {
                Row("Lid sleep", detail: Format.sentence(Format.lidEffect(s.flag)), value: Format.lidSleep(s.flag))
                Row("Display sleep", detail: model.displayAwake ? "The screen stays on while you are idle." : "Uses your macOS display settings.",
                    value: model.displayAwake ? "Off" : "On")
                ForEach(d.holds, id: \.name) { hold in
                    Row(Format.hold(hold, now: s.inputs.now))
                }
                if let pause = d.pause {
                    Row("Paused", value: Format.capitalized(Format.pause(pause)))
                }
                if let error = s.status?.error {
                    Label(Format.capitalized(error), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if let error = model.displayError {
                    Label(Format.capitalized(error), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            Panel(note: Format.guards) {
                if let b = s.inputs.battery {
                    Row("Battery", value: Format.battery(b))
                }
                Row("Thermal state", value: Format.thermal(s.inputs.thermal))
                Row("Low Power", value: Format.lowPower(setByAwake: s.savedEnergy != nil))
            }

            Panel("Updates") {
                Toggle(isOn: Binding(get: { updates.automatic }, set: updates.setAutomatic)) {
                    Row("Automatic updates", detail: "Download quietly and install when you quit Awake.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Row("Version", value: UpdateController.installedVersion)
                    Text(updateDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(updates.state == .error ? .orange : Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("updateStatus")
                    HStack {
                        if [.checking, .downloading, .extracting, .installing].contains(updates.state) {
                            if let progress = updates.progress, updates.state == .downloading {
                                ProgressView(value: progress)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Spacer()
                        Button(updateAction) {
                            if updates.state == .ready { updates.installNow() }
                            else if updates.needsDownloads { updates.openDownloads() }
                            else { updates.checkNow() }
                        }
                        .disabled(updates.state != .ready && !updates.needsDownloads && !updates.canCheck)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: Palette.canvas))
        .toggleStyle(TrailingSwitch())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.snapshot = Snapshot.take()
            }
        }
    }

    private var updateAction: String {
        if updates.state == .ready { return "Restart to update" }
        if updates.needsDownloads { return "Open downloads" }
        return updates.state == .error ? "Retry" : "Check for updates"
    }

    private var updateDetail: String {
        switch updates.state {
        case .idle: return updates.automatic ? "Updates are checked after launch and every six hours." : "Automatic updates are off. You can check for updates manually."
        case .checking: return "Checking for newer versions…"
        case .current: return "Awake is up to date."
        case .downloading: return "Downloading Awake \(updates.version ?? "update")…"
        case .extracting: return "Preparing the update…"
        case .ready: return "Awake \(updates.version ?? "update") is ready. It will install when you quit."
        case .installing: return "Installing the update…"
        case .error: return updates.message ?? "The update could not be checked. Try again later."
        }
    }
}

/// The window's colours: the system's light look, and in dark mode AdBlock's black canvas with flat
/// panels and hairlines.
@MainActor
enum Palette {
    /// Also the window's background, so the title bar shows it.
    static let canvas = dynamic(light: .white, dark: .black)
    static let card = Color(nsColor: dynamic(light: gray(0.973), dark: rgb(0.110, 0.110, 0.118)))
    static let line = Color(nsColor: dynamic(light: gray(0.937), dark: rgb(0.173, 0.173, 0.184)))
    static let ink = Color(nsColor: dynamic(light: .labelColor, dark: rgb(0.929, 0.933, 0.941)))
    static let secondaryInk = Color(nsColor: dynamic(light: .secondaryLabelColor, dark: rgb(0.604, 0.616, 0.643)))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func gray(_ w: Double) -> NSColor { rgb(w, w, w) }
}

/// Rows on a flat surface with a hairline border and hairlines between them, with an optional label
/// above and note below.
struct Panel<Content: View>: View {
    let label: String?
    let note: String?
    @ViewBuilder let content: Content

    init(_ label: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.note = note
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Palette.line.frame(height: 1)
                        }
                        row.padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: shape)
            .overlay { shape.strokeBorder(Palette.line, lineWidth: 1) }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// A title with an optional detail under it and an optional value at the trailing edge.
struct Row: View {
    let title: String
    var detail: String? = nil
    var value: String? = nil

    init(_ title: String, detail: String? = nil, value: String? = nil) {
        self.title = title
        self.detail = detail
        self.value = value
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value).font(.system(size: 13)).foregroundStyle(Palette.secondaryInk).fixedSize()
            }
        }
    }
}

/// Mac switches hug their labels; these sit at the row's trailing edge, as in AdBlock.
private struct TrailingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Toggle(configuration)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .accessibilityRepresentation {
            Toggle(configuration).toggleStyle(.switch)
        }
    }
}
