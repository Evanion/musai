import Foundation

/// Installs the loop into a host's settings, reversibly: a backup of what was there is kept, and merging twice
/// changes nothing.
public enum MusaiInstall {
    public static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"]

    /// The events we rely on, with the matcher and timeout each needs. `SessionStart` is what hands the agent
    /// the slice; `UserPromptSubmit` carries the person's turn; `PostToolUse` and `Stop` feed the queue.
    public static func claudeCodeHooksSettings(executable: String) -> Data {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"

        func entry(_ event: String, matcher: String?, timeout: Int, background: Bool) -> [String: Any] {
            var hook: [String: Any] = [
                "type": "command",
                // `|| true` and the discarded stderr are the promise: a hook can never fail the session.
                "command": "\(quoted) hook \(event) 2>/dev/null || true",
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
    public static func merge(claudeCodeHooksSettings ours: Data, into existing: Data) throws -> Data {
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
    public static func install(executable: String, settingsURL: URL) throws -> String {
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

    static func commands(in entry: [String: Any]) -> [String] {
        ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }

    private static func render(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}
