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
        let memories = try await db.query(MemoriesForProjectQuery(.init(slug: project))).memories
        for memory in newestFirst(memories) {
            guard let said = prose(of: memory) else { continue }
            lines.append("- \(said) (remembered)")
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

    /// Newest first by when the memory's session began. `createdAt` cannot order this: on a migrated row
    /// it is the moment of the import, so an imported corpus would sort as if all of it happened today.
    /// A memory the engine returned without a session sorts last rather than jumping the queue, and the
    /// write time then breaks ties within one session.
    private static func newestFirst(
        _ memories: [MemoriesForProjectQuery.Data.Memories]
    ) -> [MemoriesForProjectQuery.Data.Memories] {
        memories.sorted { left, right in
            switch (left.session?.startedAt, right.session?.startedAt) {
            case let (after?, before?):
                return after == before ? left.createdAt > right.createdAt : after > before
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.createdAt > right.createdAt
            }
        }
    }

    /// What a memory has to say, on one line. A memory may hold only a narrative, and one with neither is
    /// nothing to hand over rather than an empty bullet.
    private static func prose(of memory: MemoriesForProjectQuery.Data.Memories) -> String? {
        for candidate in [memory.text, memory.narrative] {
            let said = candidate.map(oneLine)?.trimmingCharacters(in: .whitespaces)
            if let said, !said.isEmpty { return said }
        }
        return nil
    }

    private static func oneLine(_ text: String) -> String {
        text.split(separator: "\n").joined(separator: " ")
    }
}
