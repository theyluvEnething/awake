import Observation
import SwiftUI

@MainActor @Observable
final class AwakeModel {
    var snapshot: Snapshot

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}

/// The settings window: the same Awake toggle as the menu, Stay awake indefinitely, and what awake
/// sees right now. `awake status` prints the same rows.
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
                    Text(Format.mode(.auto))
                    Text(Format.sentence(Format.explain(.auto)))
                }
                Toggle(isOn: Binding(get: { d.mode == .on }, set: setIndefinitely)) {
                    Text(Format.mode(.on))
                    Text(Format.sentence(Format.explain(.on)))
                }
            }

            Section("Now") {
                LabeledContent {
                    Text(Format.lidSleep(s.flag))
                } label: {
                    Text("Lid sleep")
                    Text(Format.sentence(Format.lidEffect(s.flag)))
                }
                ForEach(d.holds, id: \.name) { hold in
                    Text(Format.hold(hold, now: s.inputs.now))
                }
                if let pause = d.pause {
                    LabeledContent("Paused", value: Format.capitalized(Format.pause(pause)))
                }
                if let error = s.status?.error {
                    Label(Format.capitalized(error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if s.flag {
                    Button("Sleep Now", action: sleepNow)
                }
            }

            Section {
                if let b = s.inputs.battery {
                    LabeledContent("Battery", value: Format.battery(b))
                }
                LabeledContent("Thermal state", value: Format.thermal(s.inputs.thermal))
                LabeledContent("Low Power", value: Format.lowPower(setByAwake: s.savedEnergy != nil))
            } footer: {
                Text(Format.guards)
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
