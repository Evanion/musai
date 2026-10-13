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
        #expect(
            NorvoSchema.migrations.map(\.name) == [
                "0001_init", "0002_loop", "0003_decision_required", "0004_event_expiry",
                "0005_migrated_state", "0006_import_cursor",
            ])
    }

    @Test func migratedIsAnAppendedEnumCase() async throws {
        #expect(DecisionState.migrated.rawValue == "MIGRATED")
    }

    @Test func theImportCursorRoundTrips() async throws {
        let lib = try await MusaiLibrary.inMemory()
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "observations"))).importCursor == nil)

        _ = try await lib.db.mutate(
            SetImportCursorMutation(.init(source: "observations", highWaterId: 42)),
            as: MusaiActors.curator)
        let first = try await lib.db.query(ImportCursorQuery(.init(source: "observations"))).importCursor
        #expect(first?.highWaterId == 42)
        // `updatedAt` is the type's built-in stamp, never a declared field: this pins that it is populated
        // with a real wall-clock reading rather than left at an epoch.
        #expect(abs(first?.updatedAt.timeIntervalSinceNow ?? .infinity) < 60)

        _ = try await lib.db.mutate(
            SetImportCursorMutation(.init(source: "observations", highWaterId: 43)),
            as: MusaiActors.curator)
        let moved = try await lib.db.query(ImportCursorQuery(.init(source: "observations"))).importCursor
        #expect(moved?.highWaterId == 43)
        // The same row, moved: a second set must not leave a second cursor behind.
        #expect(moved?.id == first?.id)
    }
}
