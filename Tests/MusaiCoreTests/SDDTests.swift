import Foundation
import Testing
@testable import MusaiCore

@Suite struct SDDTests {
    private func project(_ lib: MusaiLibrary) async throws -> (spec: UUID, plan: UUID) {
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let spec = try await lib.db.mutate(
            CreateSpecMutation(.init(title: "Musai design", kind: .design, position: 1, slug: "musai")),
            as: MusaiActors.user).createSpec.id
        let plan = try await lib.db.mutate(
            CreatePlanMutation(.init(title: "Data model", slug: "musai")), as: MusaiActors.user).createPlan.id
        _ = try await lib.db.mutate(
            LinkPlanToSpecMutation(.init(plan: plan, spec: spec)), as: MusaiActors.user)
        return (spec, plan)
    }

    @Test func theArcLinksProjectToSpecToPlanToTask() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let (spec, plan) = try await project(lib)
        let task = try await lib.db.mutate(
            CreateTaskMutation(.init(title: "Write the schema", position: 1, plan: plan, slug: "musai")),
            as: MusaiActors.user).createTask.id

        let specs = try await lib.db.query(SpecsForProjectQuery(.init(slug: "musai"))).specs
        #expect(specs.map(\.id) == [spec])
        #expect(specs.first?.plans.first?.id == plan)
        let plans = try await lib.db.query(PlansForProjectQuery(.init(slug: "musai"))).plans
        #expect(plans.first?.spec?.id == spec)
        let tasks = try await lib.db.query(TasksForPlanQuery(.init(plan: plan))).tasks
        #expect(tasks.map(\.id) == [task])
        let todo = try await lib.db.query(TasksForProjectByStatusQuery(.init(slug: "musai", status: .todo))).tasks
        #expect(todo.count == 1)
    }

    @Test func anIdeaBecomesAProject() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let idea = try await lib.db.mutate(
            CreateIdeaMutation(.init(title: "A workspace with memory", slug: "musai")), as: MusaiActors.user).createIdea.id
        let spawned = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "spinoff")), as: MusaiActors.user).createProject.id
        _ = try await lib.db.mutate(PromoteIdeaMutation(.init(id: idea, project: spawned)), as: MusaiActors.user)

        let ideas = try await lib.db.query(AllIdeasQuery()).ideas
        #expect(ideas.first?.status == .promoted)
        #expect(ideas.first?.spawnedProject?.slug == "spinoff")
    }

    @Test func deletingAPlanLeavesItsTasks() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let (_, plan) = try await project(lib)
        let task = try await lib.db.mutate(
            CreateTaskMutation(.init(title: "Ship it", plan: plan, slug: "musai")), as: MusaiActors.user).createTask.id
        _ = try await lib.db.mutate(DeletePlanMutation(.init(id: plan)), as: MusaiActors.user)

        let plans = try await lib.db.query(PlansForProjectQuery(.init(slug: "musai"))).plans
        #expect(plans.isEmpty)
        let tasks = try await lib.db.query(TasksForPlanQuery(.init(plan: plan))).tasks
        #expect(tasks.isEmpty)
        let orphans = try await lib.db.query(
            TasksForProjectByStatusQuery(.init(slug: "musai", status: .todo))).tasks
        #expect(orphans.map(\.id) == [task])
        #expect(orphans.first?.plan?.id == nil)
    }
}
