import Foundation
import Testing
@testable import MusaiCore

@Suite struct InstallTests {
    private func hooks(_ data: Data) -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["hooks"] as? [String: Any]) ?? [:]
    }

    private func commands(_ hooks: [String: Any], _ event: String) -> [String] {
        let entries = (hooks[event] as? [[String: Any]]) ?? []
        return entries.flatMap { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }
    }

    @Test func theSettingsNameEveryHookWeRelyOn() throws {
        let data = MusaiInstall.claudeCodeHooksSettings(executable: "/usr/local/bin/musai")
        let hooks = hooks(data)
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"])
        for event in ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"] {
            let found = commands(hooks, event)
            #expect(found.count == 1)
            #expect(found.first?.contains("hook \(event)") == true)
            #expect(found.first?.contains("/usr/local/bin/musai") == true)
        }
        #expect((hooks["SessionStart"] as? [[String: Any]])?.first?["matcher"] as? String == "startup|resume|clear")
    }

    @Test func everyCommandCannotFailTheSession() throws {
        let data = MusaiInstall.claudeCodeHooksSettings(executable: "/usr/local/bin/musai")
        for event in ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"] {
            for command in commands(hooks(data), event) {
                #expect(command.hasSuffix("|| true"))
            }
        }
    }

    @Test func mergingIntoAnExistingFileKeepsOtherHooks() throws {
        let existing = Data(
            #"""
            {"hooks":{"SessionStart":[{"matcher":"^(startup|resume|clear|compact|fork)$","hooks":[{"type":"command","command":"bash '/Users/x/.claude/hooks/herdr-agent-state.sh' session","timeout":10}]}]}}
            """#.utf8)
        let merged = try MusaiInstall.merge(
            claudeCodeHooksSettings: MusaiInstall.claudeCodeHooksSettings(executable: "/usr/local/bin/musai"),
            into: existing)
        let hooks = hooks(merged)
        #expect(commands(hooks, "SessionStart").count == 2)
        #expect(commands(hooks, "SessionStart").contains { $0.contains("herdr-agent-state.sh") })
        #expect(commands(hooks, "SessionStart").contains { $0.contains("musai") })
    }

    @Test func mergingTwiceDoesNotDuplicateOurHooks() throws {
        let ours = MusaiInstall.claudeCodeHooksSettings(executable: "/usr/local/bin/musai")
        let once = try MusaiInstall.merge(claudeCodeHooksSettings: ours, into: Data("{}".utf8))
        let twice = try MusaiInstall.merge(claudeCodeHooksSettings: ours, into: once)
        #expect(commands(hooks(twice), "Stop").count == 1)
        #expect(commands(hooks(twice), "SessionStart").count == 1)
    }
}
