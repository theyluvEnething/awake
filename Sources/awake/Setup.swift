import Foundation
import ServiceManagement

/// Every file setup owns, derived from explicit locations so file operations can use a temporary home.
struct SetupPaths: Sendable {
    static let requiredApp = URL(fileURLWithPath: "/Applications/Awake.app")
    static let binary = requiredApp.appending(path: "Contents/MacOS/awake").path

    let app: URL
    let home: URL

    var atRequiredLocation: Bool { app.standardizedFileURL.path == Self.requiredApp.path }
    var codexDirectory: URL { home.appending(path: ".codex") }
    var codexHooks: URL { codexDirectory.appending(path: "hooks.json") }
    var state: URL { home.appending(path: "Library/Application Support/awake") }
    var log: URL { home.appending(path: "Library/Logs/awake.log") }
}

enum CodexSetupStatus: Equatable {
    case notInstalled, missing, installed
    case failed(String)
}

struct SetupSnapshot {
    var atRequiredLocation: Bool
    var helper: SMAppService.Status = .notRegistered
    var menu: SMAppService.Status = .notRegistered
    var reconcile: SMAppService.Status = .notRegistered
    var codex: CodexSetupStatus = .missing

    var complete: Bool {
        atRequiredLocation && helper == .enabled && menu == .enabled && reconcile == .enabled
            && (codex == .installed || codex == .notInstalled)
    }

    var needsApproval: Bool {
        [helper, menu, reconcile].contains(.requiresApproval)
    }

    var needsInstallation: Bool {
        atRequiredLocation && ([helper, menu, reconcile].contains { $0 != .enabled && $0 != .requiresApproval }
            || (codex != .installed && codex != .notInstalled))
    }
}

enum SetupService: CaseIterable {
    case helper, menu, reconcile

    @MainActor var service: SMAppService {
        switch self {
        case .helper: .daemon(plistName: Identity.helper + ".plist")
        case .menu: .agent(plistName: Identity.menu + ".plist")
        case .reconcile: .agent(plistName: Identity.reconcile + ".plist")
        }
    }
}

/// Reading setup never registers anything. Its writing functions are called only from explicit UI actions.
enum Setup {
    enum Problem: LocalizedError {
        case location

        var errorDescription: String? { Format.setupLocation }
    }

    @MainActor
    static func snapshot(paths: SetupPaths) -> SetupSnapshot {
        guard paths.atRequiredLocation else { return SetupSnapshot(atRequiredLocation: false) }
        let codex: CodexSetupStatus
        if !FileManager.default.fileExists(atPath: paths.codexDirectory.path) {
            codex = .notInstalled
        } else {
            do {
                codex = try SetupHooks.codexInstalled(at: paths.codexHooks, binary: SetupPaths.binary) ? .installed : .missing
            } catch {
                codex = .failed(error.localizedDescription)
            }
        }
        return SetupSnapshot(atRequiredLocation: true, helper: SetupService.helper.service.status,
                             menu: SetupService.menu.service.status, reconcile: SetupService.reconcile.service.status,
                             codex: codex)
    }

    @MainActor
    static func register(_ part: SetupService, app: URL) throws {
        guard app.standardizedFileURL.path == SetupPaths.requiredApp.path else { throw Problem.location }
        let service = part.service
        guard service.status != .enabled && service.status != .requiresApproval else { return }
        try service.register()
    }

    /// Wait for the background job to stop before deleting any state it could recreate.
    @MainActor
    static func unregisterBackground(_ part: SetupService, app: URL) async throws {
        guard app.standardizedFileURL.path == SetupPaths.requiredApp.path else { throw Problem.location }
        precondition(part != .menu)
        let service = part.service
        guard service.status != .notRegistered && service.status != .notFound else { return }
        try await service.unregister()
    }

    /// The menu cannot await its own exit. Its caller ignores SIGTERM until Trash and quit finish.
    @MainActor
    static func unregisterMenu(app: URL) throws {
        guard app.standardizedFileURL.path == SetupPaths.requiredApp.path else { throw Problem.location }
        let service = SetupService.menu.service
        guard service.status != .notRegistered && service.status != .notFound else { return }
        try service.unregister()
    }

    static func removeUserFiles(paths: SetupPaths) throws {
        for file in [paths.state, paths.log] {
            do {
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }

    static func trashApp(at app: URL) throws {
        guard app.standardizedFileURL.path == SetupPaths.requiredApp.path else { return }
        try FileManager.default.trashItem(at: app, resultingItemURL: nil)
    }
}
