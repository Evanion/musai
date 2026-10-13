import Foundation

/// The Claude Code side of the loop: the hooks we merge into the host's `settings.json`, and the unmerge that
/// takes ours back out. It lives in the CLI, not in `MusaiCore`, because Claude Code's settings shape is the
/// adapter's knowledge — the core goes on knowing nothing about Claude Code.
enum ClaudeCodeHooks {
    static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"]

    /// The events we rely on, with the matcher and timeout each needs. `SessionStart` is what hands the agent
    /// the slice; `UserPromptSubmit` carries the person's turn; `PostToolUse` and `Stop` feed the queue.
    static func claudeCodeHooksSettings(executable: String) -> Data {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"

        func entry(_ event: String, matcher: String?, timeout: Int, background: Bool) -> [String: Any] {
            var hook: [String: Any] = [
                "type": "command",
                // `|| true` is the promise: a hook can never fail the session. Its diagnostic still reaches
                // stderr, because a capture that quietly did not happen is the one failure worth hearing about.
                "command": "\(quoted) hook \(event) || true",
                "timeout": timeout,
            ]
            if background { hook["async"] = true }
            var wrapper: [String: Any] = ["hooks": [hook]]
            if let matcher { wrapper["matcher"] = matcher }
            return wrapper
        }

        let hooks: [String: Any] = [
            "SessionStart": [entry("SessionStart", matcher: "startup|resume|clear", timeout: 60, background: false)],
            "UserPromptSubmit": [entry("UserPromptSubmit", matcher: nil, timeout: 15, background: false)],
            "PostToolUse": [entry("PostToolUse", matcher: "*", timeout: 120, background: true)],
            "Stop": [entry("Stop", matcher: nil, timeout: 120, background: true)],
        ]
        return render(["hooks": hooks])
    }

    /// Adds our entries to whatever is already there, leaving every other hook untouched.
    static func merge(claudeCodeHooksSettings ours: Data, into existing: Data) throws -> Data {
        var root = ((try? JSONSerialization.jsonObject(with: existing)) as? [String: Any]) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let ourHooks = ((try? JSONSerialization.jsonObject(with: ours)) as? [String: Any])?["hooks"] as? [String: Any]

        for (event, value) in ourHooks ?? [:] {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            for candidate in (value as? [[String: Any]]) ?? [] {
                let ours = commands(in: candidate)
                let alreadyThere = entries.contains { !Set(commands(in: $0)).isDisjoint(with: ours) }
                if !alreadyThere { entries.append(candidate) }
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return render(root)
    }

    /// Writes the merged settings and keeps a backup of what was there. Returns one line describing it.
    @discardableResult
    static func install(executable: String, settingsURL: URL) throws -> String {
        let existing = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
        let hadFile = FileManager.default.fileExists(atPath: settingsURL.path)
        let merged = try merge(
            claudeCodeHooksSettings: claudeCodeHooksSettings(executable: executable), into: existing)
        if hadFile {
            try existing.write(to: URL(fileURLWithPath: settingsURL.path + ".musai-backup"))
        }
        try merged.write(to: settingsURL)
        let backed = hadFile ? ", with a backup beside it" : ""
        return "musai: installed \(events.joined(separator: ", ")) into \(settingsURL.path)\(backed)"
    }

    /// Takes our entries back out, and only ours: every other host's hooks, and the person's own settings, are
    /// left exactly as they were. We are recognised by our command text — the `'…/musai' hook <Event> || true`
    /// shape we write — so a stale path cannot leave a hook behind. Returns one line describing it.
    @discardableResult
    static func uninstall(settingsURL: URL) throws -> String {
        guard let existing = try? Data(contentsOf: settingsURL) else {
            return "musai: nothing to uninstall in \(settingsURL.path)"
        }
        var root = ((try? JSONSerialization.jsonObject(with: existing)) as? [String: Any]) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var removed = 0

        for (event, value) in hooks {
            let entries = (value as? [[String: Any]]) ?? []
            let kept = entries.filter { !isOurs($0) }
            removed += entries.count - kept.count
            if kept.isEmpty {
                // An event we were the only entry for leaves no empty husk behind.
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        root["hooks"] = hooks
        try render(root).write(to: settingsURL)
        return "musai: removed \(removed) hook\(removed == 1 ? "" : "s") from \(settingsURL.path)"
    }

    /// Whether an entry is one we wrote: every command in it is a musai hook of the shape above. Matching the
    /// text rather than the executable's path keeps an install made from another build removable.
    static func isOurs(_ entry: [String: Any]) -> Bool {
        let entryCommands = commands(in: entry)
        guard !entryCommands.isEmpty else { return false }
        return entryCommands.allSatisfy { command in
            command.hasSuffix("|| true") && events.contains { command.contains(" hook \($0) ") }
        }
    }

    static func commands(in entry: [String: Any]) -> [String] {
        ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }

    private static func render(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}
