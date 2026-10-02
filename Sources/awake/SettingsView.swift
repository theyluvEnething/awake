import Observation
import SwiftUI

@MainActor @Observable
final class AwakeModel {
    var snapshot: Snapshot

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}

/// The settings window: the same Awake switch as the menu, staying awake indefinitely, and what
/// awake sees right now.
struct SettingsView: View {
    let model: AwakeModel
    let setAwake: @MainActor @Sendable (Bool) -> Void
    let setIndefinitely: @MainActor @Sendable (Bool) -> Void
    let sleepNow: @MainActor @Sendable () -> Void

    var body: some View {
        let s = model.snapshot
        let d = s.decision
        Form {
            Section {
                Toggle(isOn: Binding(get: { d.mode != .off }, set: setAwake)) {
                    Text("Awake")
                    Text("Keeps the Mac running with the lid closed while Claude or Codex works.")
                }
                Toggle(isOn: Binding(get: { d.mode == .on }, set: setIndefinitely)) {
                    Text("Stay awake indefinitely")
                    Text("Even when nothing runs, until you turn it off, restart or log out.")
                }
            }

            Section("Now") {
                LabeledContent("Closing the lid", value: s.flag ? "Keeps it running" : "Puts it to sleep")
                ForEach(d.holds, id: \.name) { hold in
                    Text(Format.label(hold, now: s.inputs.now))
                }
                if let pause = d.pause, !d.holds.isEmpty {
                    LabeledContent("Paused", value: pause.prefix(1).uppercased() + pause.dropFirst())
                }
                if let error = s.status?.error {
                    Label(error.prefix(1).uppercased() + error.dropFirst(), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if s.flag {
                    Button("Sleep Now", action: sleepNow)
                }
            }

            Section {
                if let b = s.inputs.battery {
                    LabeledContent("Charge", value: "\(b.level) %, " +
                                   (b.charging ? "charging" : b.external ? "on power, not charging" : "on battery"))
                    if let t = b.temperature {
                        LabeledContent("Temperature", value: String(format: "%.1f °C", t))
                    }
                }
                LabeledContent("Thermal state", value: "\(s.inputs.thermal)".capitalized)
                LabeledContent("Low Power", value: s.savedEnergy == nil ? "Not set by Awake"
                               : "On while the lid is closed, set by Awake")
            } header: {
                Text("Battery")
            } footer: {
                Text("Awake lets the Mac sleep at 20 % battery unless it's charging, at 40 °C battery temperature and when macOS reports heavy thermal pressure.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.snapshot = Snapshot.take()
            }
        }
    }
}
