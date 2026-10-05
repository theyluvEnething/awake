import Foundation
import ServiceManagement
import Testing
@testable import awake

private let binary = "/Applications/Awake.app/Contents/MacOS/awake"
private let codexCommand = "[ -x /Applications/Awake.app/Contents/MacOS/awake ] && exec /Applications/Awake.app/Contents/MacOS/awake hook codex; exit 0"
private let claudeCommand = "[ -x /Applications/Awake.app/Contents/MacOS/awake ] && exec /Applications/Awake.app/Contents/MacOS/awake hook claude; exit 0"

private func object(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

@Suite struct SetupStateTests {
    @Test func completionRequiresTheApplicationLocationEveryServiceAndCodexWhenPresent() {
        var state = SetupSnapshot(atRequiredLocation: true, helper: .enabled, menu: .enabled,
                                  reconcile: .enabled, codex: .installed)
        #expect(state.complete)
        #expect(!state.needsInstallation)
        state.codex = .notInstalled
        #expect(state.complete)
        state.codex = .missing
        #expect(!state.complete)
        #expect(state.needsInstallation)
        state.codex = .installed
        state.helper = .requiresApproval
        #expect(!state.complete)
        #expect(!state.needsInstallation)
        state.helper = .enabled
        state.menu = .notRegistered
        #expect(!state.complete)
        state.menu = .enabled
        state.reconcile = .notFound
        #expect(!state.complete)
        state.reconcile = .enabled
        state.atRequiredLocation = false
        #expect(!state.complete)
    }

    @Test func locationsOutsideApplicationsNeverCountAsInstalled() {
        let home = URL(fileURLWithPath: "/unused-home")
        #expect(SetupPaths(app: URL(fileURLWithPath: "/Applications/Awake.app"), home: home).atRequiredLocation)
        #expect(SetupPaths(app: URL(fileURLWithPath: "/Applications/Awake.app", isDirectory: true), home: home)
            .atRequiredLocation)
        for path in ["/Downloads/Awake.app", "/Volumes/Awake/Awake.app", "/unused-home/Applications/Awake.app",
                     "/private/var/folders/translocated/Awake.app"] {
            #expect(!SetupPaths(app: URL(fileURLWithPath: path), home: home).atRequiredLocation)
        }
    }

    @Test func uninstallFilesAreScopedToTheSuppliedHome() throws {
        try withHooksFile { file in
            let home = file.deletingLastPathComponent()
            let paths = SetupPaths(app: home.appending(path: "Awake.app"), home: home)
            try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
            try Data("state".utf8).write(to: paths.state.appending(path: "mode"))
            try FileManager.default.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("log".utf8).write(to: paths.log)
            let other = paths.state.deletingLastPathComponent().appending(path: "keep.txt")
            try Data("keep".utf8).write(to: other)
            try Setup.removeUserFiles(paths: paths)
            #expect(!FileManager.default.fileExists(atPath: paths.state.path))
            #expect(!FileManager.default.fileExists(atPath: paths.log.path))
            #expect(try String(contentsOf: other, encoding: .utf8) == "keep")
            try Setup.removeUserFiles(paths: paths)
        }
    }
}

private func withHooksFile(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "awake-setup-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder.appending(path: "hooks.json"))
}

@Suite struct SetupHooksTests {
    @Test func freshCodexInstallHasTheSixEventsAndOnlySessionEndIsSynchronous() throws {
        let merged = try #require(try SetupHooks.mergeCodex([:], binary: binary, install: true))
        let expected = try object("""
            {"hooks": {
              "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\(codexCommand)", "async": true}]}],
              "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "\(codexCommand)", "async": true}]}],
              "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "\(codexCommand)", "async": true}]}],
              "Stop": [{"hooks": [{"type": "command", "command": "\(codexCommand)", "async": true}]}],
              "Interrupt": [{"hooks": [{"type": "command", "command": "\(codexCommand)", "async": true}]}],
              "SessionEnd": [{"hooks": [{"type": "command", "command": "\(codexCommand)"}]}]
            }}
            """)
        #expect(NSDictionary(dictionary: merged).isEqual(to: expected))
    }

    @Test func replacesOldAwakeGroupsAtTheirFirstPositionAndKeepsOtherContent() throws {
        let document = try object("""
            {"version": 3, "other": {"enabled": true}, "hooks": {
              "PreToolUse": [
                {"matcher": "Read", "hooks": [{"type": "command", "command": "echo before"}]},
                {"matcher": "old", "hooks": [{"type": "command", "command": "exec ~/Applications/Awake.app/Contents/MacOS/awake hook codex"}]},
                {"matcher": "Write", "hooks": [{"type": "command", "command": "echo after"}]},
                {"hooks": [{"type": "command", "command": "Awake.app/Contents/MacOS/awake"}]}
              ],
              "CustomEvent": [{"hooks": [{"type": "prompt", "prompt": "keep me"}]}]
            }}
            """)
        let merged = try #require(try SetupHooks.mergeCodex(document, binary: binary, install: true))
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(groups.count == 3)
        #expect(groups[0]["matcher"] as? String == "Read")
        #expect(groups[1]["matcher"] as? String == "*")
        #expect((groups[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String == codexCommand)
        #expect(groups[2]["matcher"] as? String == "Write")
        #expect(merged["version"] as? Int == 3)
        #expect((merged["other"] as? [String: Bool]) == ["enabled": true])
        let originalHooks = try #require(document["hooks"] as? [String: Any])
        #expect(NSArray(array: try #require(hooks["CustomEvent"] as? [Any]))
            .isEqual(to: try #require(originalHooks["CustomEvent"] as? [Any])))
    }

    @Test func uninstallRemovesOnlyAwakeGroupsAndDropsEmptyEvents() throws {
        let document = try object("""
            {"other": 42, "hooks": {
              "Stop": [{"hooks": [{"command": "\(codexCommand)"}]}, {"hooks": [{"command": "echo keep"}]}],
              "OldEvent": [{"hooks": [{"command": "Awake.app/Contents/MacOS/awake"}]}],
              "EmptyEvent": []
            }}
            """)
        let merged = try #require(try SetupHooks.mergeCodex(document, binary: binary, install: false))
        let expected = try object("""
            {"other": 42, "hooks": {"Stop": [{"hooks": [{"command": "echo keep"}]}]}}
            """)
        #expect(NSDictionary(dictionary: merged).isEqual(to: expected))
    }

    @Test(arguments: [true, false])
    func keepsUnrelatedHandlersInMixedGroups(install: Bool) throws {
        let document = try object("""
            {"other": 42, "hooks": {"PreToolUse": [
              {"matcher": "Write", "timeout": 12, "hooks": [
                {"type": "command", "command": "echo before", "async": false},
                {"type": "command", "command": "\(codexCommand)"},
                {"type": "prompt", "prompt": "keep me"},
                {"type": "command", "command": "exec ~/Applications/Awake.app/Contents/MacOS/awake hook codex"},
                {"type": "command", "command": "echo after", "timeout": 7}
              ]}
            ]}}
            """)
        let merged = try #require(try SetupHooks.mergeCodex(document, binary: binary, install: install))
        let hooks = try #require(merged["hooks"] as? [String: [[String: Any]]])
        let groups = try #require(hooks["PreToolUse"])
        #expect(groups.count == (install ? 2 : 1))
        let kept = try #require(groups.last)
        let expected = try object("""
            {"matcher": "Write", "timeout": 12, "hooks": [
              {"type": "command", "command": "echo before", "async": false},
              {"type": "prompt", "prompt": "keep me"},
              {"type": "command", "command": "echo after", "timeout": 7}
            ]}
            """)
        #expect(NSDictionary(dictionary: kept).isEqual(to: expected))
        #expect(merged["other"] as? Int == 42)
        if install {
            #expect(groups.first?["matcher"] as? String == "*")
            let handlers = try #require(groups.first?["hooks"] as? [[String: Any]])
            #expect(handlers.first?["command"] as? String == codexCommand)
            let again = try #require(try SetupHooks.mergeCodex(merged, binary: binary, install: true))
            #expect(NSDictionary(dictionary: again).isEqual(to: merged))
        }
    }

    @Test func uninstallKeepsTopLevelKeysEvenWhenNoHooksRemain() throws {
        let document = try object("""
            {"version": 1, "hooks": {"Stop": [{"hooks": [{"command": "\(codexCommand)"}]}]}}
            """)
        let merged = try #require(try SetupHooks.mergeCodex(document, binary: binary, install: false))
        #expect(NSDictionary(dictionary: merged).isEqual(to: ["version": 1, "hooks": [:]]))
    }

    @Test(arguments: [
        "echo /Applications/Awake.app/Contents/MacOS/awake",
        "/usr/local/bin/backup /Applications/Awake.app/Contents/MacOS/awake",
        "exec /Applications/OtherAwake.app/Contents/MacOS/awake hook codex",
        "/Applications/Awake.app/Contents/MacOS/awake status",
    ])
    func keepsCommandsThatOnlyMentionAwake(command: String) throws {
        let document: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
        let merged = try #require(try SetupHooks.mergeCodex(document, binary: binary, install: false))
        #expect(NSDictionary(dictionary: merged).isEqual(to: document))
    }

    @Test func fileInstallAndUninstallLeaveNothingWhenOnlyAwakeWasPresent() throws {
        try withHooksFile { file throws in
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: true) == .written)
            #expect(try SetupHooks.codexInstalled(at: file, binary: binary))
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: false) == .removed)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: false) == .unchanged)
        }
    }

    @Test func doesNotRewriteHooksThatAreAlreadyInstalled() throws {
        try withHooksFile { file in
            _ = try SetupHooks.updateCodex(at: file, binary: binary, install: true)
            let before = try Data(contentsOf: file)
            let oldDate = Date(timeIntervalSince1970: 1_000_000)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: true) == .unchanged)
            #expect(try Data(contentsOf: file) == before)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == oldDate)
        }
    }

    @Test func writesThroughASymlinkAndKeepsPermissions() throws {
        try withHooksFile { file in
            let linked = file.deletingLastPathComponent().appending(path: "dotfiles-hooks.json")
            try Data("{\"hooks\":{}}".utf8).write(to: linked)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: linked.path)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linked)
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: true) == .written)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == linked.path)
            #expect(try SetupHooks.codexInstalled(at: linked, binary: binary))
            #expect(try FileManager.default.attributesOfItem(atPath: linked.path)[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func uninstallKeepsTheSymlinkAndRemovesHooksFromItsTarget() throws {
        try withHooksFile { file in
            let linked = file.deletingLastPathComponent().appending(path: "dotfiles-hooks.json")
            try Data("{\"hooks\":{}}".utf8).write(to: linked)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: linked.path)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linked)
            _ = try SetupHooks.updateCodex(at: file, binary: binary, install: true)
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: false) == .written)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == linked.path)
            let document = try object(String(contentsOf: linked, encoding: .utf8))
            #expect(NSDictionary(dictionary: document).isEqual(to: ["hooks": [:]]))
            #expect(try FileManager.default.attributesOfItem(atPath: linked.path)[.posixPermissions] as? Int == 0o600)
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: false) == .unchanged)
        }
    }

    @Test func doesNotReformatAnUnchangedDocument() throws {
        try withHooksFile { file in
            let before = Data("{\"custom\":true,\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"echo hello\"}]}]}}".utf8)
            try before.write(to: file)
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: false) == .unchanged)
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test func repairsNumericAsyncValuesInsteadOfMistakingThemForTrue() throws {
        try withHooksFile { file in
            _ = try SetupHooks.updateCodex(at: file, binary: binary, install: true)
            let numeric = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: "\"async\" : true", with: "\"async\" : 1")
            try Data(numeric.utf8).write(to: file)
            #expect(try !SetupHooks.codexInstalled(at: file, binary: binary))
            #expect(try SetupHooks.updateCodex(at: file, binary: binary, install: true) == .written)
            #expect(try String(contentsOf: file, encoding: .utf8).contains("\"async\" : true"))
        }
    }

    @Test(arguments: ["{not json", "[]", "{\"hooks\":null}", "{\"hooks\":{\"Stop\":{}}}",
                      "{\"hooks\":{\"Stop\":[{\"hooks\":false}]}}"])
    func leavesUnparsableFilesUntouched(text: String) throws {
        try withHooksFile { file in
            let before = Data(text.utf8)
            try before.write(to: file)
            #expect(throws: (any Error).self) { try SetupHooks.updateCodex(at: file, binary: binary, install: true) }
            #expect(throws: (any Error).self) { try SetupHooks.updateCodex(at: file, binary: binary, install: false) }
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test func doesNotCreateACodexDirectory() throws {
        try withHooksFile { file throws in
            let missing = file.deletingLastPathComponent().appending(path: ".codex/hooks.json")
            #expect(try SetupHooks.updateCodex(at: missing, binary: binary, install: true) == .codexNotInstalled)
            #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        }
    }

    @Test func claudeJSONHasItsSevenEventsMatchersAndAsyncHandlers() throws {
        let document = try object(SetupHooks.claudeJSON(binary: binary))
        let hooks = try #require(document["hooks"] as? [String: [[String: Any]]])
        #expect(Set(document.keys) == ["hooks"])
        #expect(Set(hooks.keys) == ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                                  "Stop", "StopFailure", "SessionEnd"])
        for (event, groups) in hooks {
            #expect(groups.count == 1)
            let group = try #require(groups.first)
            let matched = ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(event)
            #expect(Set(group.keys) == (matched ? ["matcher", "hooks"] : ["hooks"]))
            #expect(group["matcher"] as? String == (matched ? "*" : nil))
            let handlers = try #require(group["hooks"] as? [[String: Any]])
            #expect(handlers.count == 1)
            #expect(NSDictionary(dictionary: try #require(handlers.first))
                .isEqual(to: ["type": "command", "command": claudeCommand, "async": true]))
        }
    }

    @Test func quotesTheBinaryAsShlexDoes() throws {
        let path = "/a folder/it's Awake.app/Contents/MacOS/awake"
        let document = try #require(try SetupHooks.mergeCodex([:], binary: path, install: true))
        let hooks = try #require(document["hooks"] as? [String: [[String: Any]]])
        let handler = try #require(hooks["Stop"]?.first?["hooks"] as? [[String: Any]])
        let q = "'/a folder/it'\"'\"'s Awake.app/Contents/MacOS/awake'"
        #expect(handler.first?["command"] as? String == "[ -x \(q) ] && exec \(q) hook codex; exit 0")
    }
}
