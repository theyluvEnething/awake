import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AwakeModel {
    var snapshot: Snapshot
    var displayAwake = false
    var displayError: String?
    var samples = ActivityHistory.load()
    var t3 = T3Monitor.State()

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}

/// Daily controls, activity history and app maintenance each have a compact page.
struct SettingsView: View {
    let model: AwakeModel
    let updates: UpdateController
    let setAwake: @MainActor @Sendable (Bool) -> Void
    let setIndefinitely: @MainActor @Sendable (Bool) -> Void
    let setKeepDisplayOn: @MainActor @Sendable (Bool) -> Void
    let openActivity: @MainActor @Sendable () -> Void
    let uninstall: @MainActor @Sendable () -> Void
    @State private var page = Page.awake

    private enum Page: String, CaseIterable, Identifiable {
        case awake = "Awake", activity = "Activity", app = "App"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 20) {
            Picker("Settings", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settingsPage")

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case .awake: controls
                    case .activity:
                        ActivityView(model: model, expanded: false)
                        Button("Open in separate window", systemImage: "arrow.up.left.and.arrow.down.right", action: openActivity)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    case .app: maintenance
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(24)
        .frame(width: 520, height: 640)
        .background(Color(nsColor: Palette.canvas))
        .toggleStyle(TrailingSwitch())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.snapshot = Snapshot.take()
            }
        }
    }

    private var controls: some View {
        let s = model.snapshot
        let d = s.decision
        return VStack(alignment: .leading, spacing: 20) {
            Panel {
                Toggle(isOn: Binding(get: { d.mode != .off }, set: setAwake)) {
                    Row(Format.mode(.auto), detail: "With the lid closed while Claude, Codex or T3 Code works.")
                }
                Toggle(isOn: Binding(get: { d.mode == .on }, set: setIndefinitely)) {
                    Row(Format.mode(.on), detail: "Until you turn it off, restart or log out.")
                }
                Toggle(isOn: Binding(get: { s.inputs.keepDisplayOn }, set: setKeepDisplayOn)) {
                    Row("Keep display on", detail: "Prevent idle dimming and display sleep.")
                }
            }

            Panel("Now") {
                Row("Lid sleep", value: Format.lidSleep(s.flag))
                Row("Display sleep", value: model.displayAwake ? "Off" : "On")
                Row("T3 Code", value: model.t3.summary)
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
                if let problem = model.t3.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(.orange)
                }
            }

            DisclosureGroup("Battery and heat protections") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Format.guards).fixedSize(horizontal: false, vertical: true)
                    Row("Low Power", value: Format.lowPower(setByAwake: s.savedEnergy != nil))
                }
                .padding(.top, 10)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondaryInk)
        }
    }

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 20) {
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
            HStack {
                Text("Remove Awake and restore normal sleep.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryInk)
                Spacer()
                Button("Uninstall Awake…", role: .destructive, action: uninstall)
                    .disabled(updates.updateInProgress)
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
