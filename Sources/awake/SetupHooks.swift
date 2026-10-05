import Foundation

/// Hook definitions and the Codex merge. Claude Code settings are only copied for the user to add.
enum SetupHooks {
    enum Change: Equatable {
        case written, removed, unchanged, codexNotInstalled
    }

    enum InvalidDocument: LocalizedError {
        case structure

        var errorDescription: String? { "hooks.json must contain an object with hook events and groups" }
    }

    /// Replaces Awake's handlers at the first old group's position, including an old ~/Applications
    /// command. Other handlers and their group metadata stay intact. Codex's trust depends on a
    /// group's position as well as its definition.
    static func mergeCodex(_ document: [String: Any], binary: String, install: Bool) throws -> [String: Any]? {
        var document = document
        guard var hooks = (document["hooks"] ?? [String: Any]()) as? [String: Any] else {
            throw InvalidDocument.structure
        }
        let wanted = install ? groups(binary: binary, agent: "codex") : [:]
        for event in Set(hooks.keys).union(wanted.keys).sorted() {
            guard let original = (hooks[event] ?? [[String: Any]]()) as? [[String: Any]] else {
                throw InvalidDocument.structure
            }
            var position: Int?
            var kept: [[String: Any]] = []
            for group in original {
                guard let handlers = (group["hooks"] ?? [[String: Any]]()) as? [[String: Any]] else {
                    throw InvalidDocument.structure
                }
                let remaining = try handlers.filter { try !ours($0, binary: binary) }
                if remaining.count == handlers.count {
                    kept.append(group)
                } else {
                    if position == nil { position = kept.count }
                    if !remaining.isEmpty {
                        var group = group
                        group["hooks"] = remaining
                        kept.append(group)
                    }
                }
            }
            if let group = wanted[event] { kept.insert(group, at: position ?? kept.count) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        document["hooks"] = hooks
        return hooks.isEmpty && document.count == 1 ? nil : document
    }

    /// Takes the hooks.json URL, never creates its parent, and never overwrites a file it cannot
    /// read and parse. An unchanged document keeps its bytes and modification time.
    @discardableResult
    static func updateCodex(at file: URL, binary: String, install: Bool) throws -> Change {
        var directory: ObjCBool = false
        if install && (!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path,
                                                       isDirectory: &directory) || !directory.boolValue) {
            return .codexNotInstalled
        }
        // Read and write the file a symlink points to, as dotfile managers link this file, and
        // resolve it once so both touch the same file.
        let linked = (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil
        let target = file.resolvingSymlinksInPath()
        let original = try read(at: target)
        var merged = try mergeCodex(original ?? [:], binary: binary, install: install)
        // Removing our last hook must leave the user's dotfile link and its target in place.
        if merged == nil && linked { merged = ["hooks": [String: Any]()] }
        guard let merged else {
            guard original != nil else { return .unchanged }
            try FileManager.default.removeItem(at: target)
            return .removed
        }
        // NSDictionary equates JSON true with 1. Encoded values preserve that distinction.
        if let original, try encoded(original) == encoded(merged) { return .unchanged }
        let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try encoded(merged).write(to: target, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return .written
    }

    /// Read-only: all six current definitions must already be present, without duplicate old ones.
    static func codexInstalled(at file: URL, binary: String) throws -> Bool {
        guard let original = try read(at: file),
              let merged = try mergeCodex(original, binary: binary, install: true) else { return false }
        return try encoded(original) == encoded(merged)
    }

    static func claudeJSON(binary: String) throws -> String {
        let hooks = groups(binary: binary, agent: "claude").mapValues { [$0] }
        return String(decoding: try encoded(["hooks": hooks]), as: UTF8.self)
    }

    private static func groups(binary: String, agent: String) -> [String: [String: Any]] {
        let q = quote(binary)
        let command = "[ -x \(q) ] && exec \(q) hook \(agent); exit 0"
        let events = agent == "codex"
            ? ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
            : ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd"]
        return Dictionary(uniqueKeysWithValues: events.map { event in
            var handler: [String: Any] = ["type": "command", "command": command]
            // Codex always runs SessionEnd synchronously and warns about an async key there.
            if agent != "codex" || event != "SessionEnd" { handler["async"] = true }
            var group: [String: Any] = ["hooks": [handler]]
            if ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(event) { group["matcher"] = "*" }
            return (event, group)
        })
    }

    private static func ours(_ handler: [String: Any], binary: String) throws -> Bool {
        guard let command = (handler["command"] ?? "") as? String else { throw InvalidDocument.structure }
        guard handler["type"] == nil || handler["type"] as? String == "command" else { return false }
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications/Awake.app/Contents/MacOS/awake").path
        return [binary, legacy, "~/Applications/Awake.app/Contents/MacOS/awake", "Awake.app/Contents/MacOS/awake"]
            .contains { path in
                let forms = path.hasPrefix("~/") ? [path, quote(path)] : [quote(path)]
                return forms.contains { q in
                    command == q || command == "\(q) hook codex" || command == "exec \(q) hook codex"
                        || command == "[ -x \(q) ] && exec \(q) hook codex; exit 0"
                }
            }
    }

    /// The ASCII safe set and single-quote escaping used by Python's shlex.quote.
    private static func quote(_ text: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !text.isEmpty && text.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func read(at file: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InvalidDocument.structure
        }
        return document
    }

    private static func encoded(_ document: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: document,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        return data
    }
}
