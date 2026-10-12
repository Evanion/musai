import Foundation
import NorvoLite

/// The bounded slice of what Musai knows, handed to an agent when a task starts.
public enum MusaiSlice {
    public static let defaultBudget = 2_000
    /// Held back so the "there is more" line always fits inside the budget.
    private static let reserve = 40

    /// `nil` when there is nothing to say, so a session start stays quiet on an empty store.
    public static func render(project: String, budget: Int = defaultBudget, db: Database) async throws -> String? {
        var lines: [String] = []
        let decisions = try await db.query(DecisionsForProjectQuery(.init(slug: project))).decisions
        for decision in decisions {
            var line = "- \(decision.title) — \(decision.act.displayName)"
            if let reference = decision.documentRef { line += ", landed at \(reference)" }
            // A constraint or an example is where the exact wording matters, so it is quoted.
            if (decision.act == .constraint || decision.act == .example), let said = decision.utterance?.text {
                line += "\n  “\(oneLine(said))”"
            }
            lines.append(line)
        }
        let doing = try await db.query(
            TasksForProjectByStatusQuery(.init(slug: project, status: .doing))).tasks
        for task in doing { lines.append("- \(task.title) (in progress)") }
        guard !lines.isEmpty else { return nil }

        let header = "Musai knows this project:"
        var rendered: [String] = []
        var used = header.utf8.count + 1
        var omitted = 0
        for line in lines {
            let size = line.utf8.count + 1
            if used + size + reserve > budget {
                omitted += 1
                continue
            }
            rendered.append(line)
            used += size
        }
        guard !rendered.isEmpty else { return nil }
        var text = header + "\n" + rendered.joined(separator: "\n")
        if omitted > 0 { text += "\n(+\(omitted) more)" }
        return text
    }

    /// The host's own stdout shape for the session-start hook.
    public static func additionalContext(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":["\#(escaped)"]}}"#
    }

    private static func oneLine(_ text: String) -> String {
        text.split(separator: "\n").joined(separator: " ")
    }
}
