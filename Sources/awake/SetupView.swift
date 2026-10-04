import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class SetupModel {
    var snapshot: SetupSnapshot
    var installing = false
    var serviceErrors: [SetupService: String] = [:]
    var codexError: String?
    var powerError: String?
    var copyError: String?
    var copied = false

    init(snapshot: SetupSnapshot) {
        self.snapshot = snapshot
    }
}

/// One setup window. The view only displays supplied state; its owner starts and stops approval polling.
struct SetupView: View {
    let model: SetupModel
    let install: @MainActor () -> Void
    let openSystemSettings: @MainActor () -> Void
    let copyHooks: @MainActor () -> Void
    let showInFinder: @MainActor () -> Void
    let quit: @MainActor () -> Void
    let done: @MainActor () -> Void

    var body: some View {
        Group {
            if model.snapshot.atRequiredLocation {
                setup
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Row("Move Awake to Applications", detail: Format.setupLocation)
                    HStack {
                        Button("Show in Finder", action: showInFinder)
                        Spacer()
                        Button("Quit Awake", action: quit).keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 440)
        .background(Color(nsColor: Palette.canvas))
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(Format.setupPurpose)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Panel("What Awake installs") {
                        VStack(alignment: .leading, spacing: 8) {
                            Row("Privileged helper", detail: Format.setupHelper)
                            Text(Format.setupHelperCommands)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.secondaryInk)
                                .textSelection(.enabled)
                        }
                        Row("Two login items", detail: Format.setupLoginItems)
                        Row("Codex hooks", detail: Format.setupCodex)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button(model.installing ? "Setting Up…" : "Set Up Awake", action: install)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.installing || !model.snapshot.needsInstallation)
                            .keyboardShortcut(model.snapshot.complete ? nil : .defaultAction)
                        statuses
                    }

                    Panel("Claude Code") {
                        VStack(alignment: .leading, spacing: 8) {
                            Row("Add these hooks yourself", detail: Format.setupClaude)
                            Text(Format.setupClaudeManaged)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryInk)
                            Text(Format.setupClaudeManagedPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.secondaryInk)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Button("Copy Hooks", action: copyHooks)
                                if model.copied {
                                    Label("Copied", systemImage: "checkmark")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.secondaryInk)
                                }
                            }
                            if let error = model.copyError { problem(error) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .frame(height: min(740, max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 120)))
            HStack {
                if model.snapshot.complete {
                    Label("Setup complete", systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryInk)
                }
                Spacer()
                Button("Done", action: done)
                    .disabled(!model.snapshot.complete || model.installing)
                    .keyboardShortcut(model.snapshot.complete ? .defaultAction : nil)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
    }

    private var statuses: some View {
        VStack(alignment: .leading, spacing: 8) {
            serviceStatus("Helper", part: .helper, status: model.snapshot.helper)
            serviceStatus("Menu at login", part: .menu, status: model.snapshot.menu)
            serviceStatus("30-second check", part: .reconcile, status: model.snapshot.reconcile)
            // One switch in System Settings allows all three.
            if model.snapshot.needsApproval {
                HStack(spacing: 12) {
                    Button("Open System Settings", action: openSystemSettings)
                    Text(Format.setupApproval)
                }
            }
            codexStatus
            if let error = model.powerError { problem(error) }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func serviceStatus(_ title: String, part: SetupService, status: SMAppService.Status) -> some View {
        if let error = model.serviceErrors[part], status != .enabled && status != .requiresApproval {
            problem(title + ": " + error)
        } else {
            switch status {
            case .enabled:
                Label(title + (part == .helper ? ": allowed" : ": enabled"), systemImage: "checkmark.circle")
            case .requiresApproval:
                Label {
                    Text(title + ": waiting for approval")
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
            // macOS 26 reports an item it has never registered as notFound.
            case .notRegistered, .notFound:
                Label(title + ": not set up", systemImage: "circle")
            @unknown default:
                Label(title + ": status unavailable", systemImage: "questionmark.circle")
            }
        }
    }

    @ViewBuilder
    private var codexStatus: some View {
        switch model.snapshot.codex {
        case .installed:
            Label("Codex hooks: installed", systemImage: "checkmark.circle")
            Text(Format.setupCodexTrust).font(.system(size: 11))
        case .notInstalled:
            Label(Format.setupCodexMissing, systemImage: "info.circle")
            Text(Format.setupCodexLater).font(.system(size: 11))
        case .missing:
            if let error = model.codexError {
                problem("Codex hooks: " + error)
            } else {
                Label("Codex hooks: not set up", systemImage: "circle")
            }
        case .failed(let error):
            problem("Codex hooks left untouched: " + error)
        }
    }

    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink)
    }
}
