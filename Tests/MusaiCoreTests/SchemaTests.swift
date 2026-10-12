import Foundation
import Testing
@testable import MusaiCore

@Suite struct SchemaTests {
    @Test func theGraphMigratesAndIntrospects() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let sdl = try await lib.db.schema()
        for type in ["Project", "Idea", "Spec", "Plan", "Task", "Decision", "Memory", "Session", "WorkState", "Link"] {
            #expect(sdl.contains("type \(type)"))
        }
        #expect(NorvoSchema.migrations.map(\.name) == ["0001_init", "0002_loop", "0003_decision_required"])
    }
}
