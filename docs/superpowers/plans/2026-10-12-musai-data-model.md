# Musai data model on Norvo Lite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `MusaiCore`, the Swift library that holds Musai's project graph — schema, migrations, typed operations and a thin open/migrate façade — on Norvo Lite, tested end to end.

**Architecture:** One NorvoQL project (`schema.nql`, `migrations/`, `operations/`) inside the `MusaiCore` target; the `NorvoCodegen` build plugin turns it into typed Swift (`NorvoSchema.migrations`, one type per operation). `MusaiLibrary` opens and migrates the file so no caller forgets to; `ProjectBinder` holds the one piece of real resolution logic (cwd + git remote → Project). This is build-order step 1 of the spec (`§16.1`) minus the claude-mem import, which is its own plan.

**Tech Stack:** Swift 6.1 tools / Swift 6.4 toolchain, Swift Testing, NorvoLite Swift package (NorvoQL + C ABI), macOS 14+ arm64.

**Spec:** `docs/superpowers/specs/2026-10-12-musai-design.md`

## Global Constraints

- Platform: **macOS, Apple Silicon only** (arm64). The package declares `.macOS(.v14)`.
- Engine: **Norvo Lite only**, embedded via the `NorvoLite` Swift package and its C ABI. No second datastore, no SQLite, no files of our own besides the Norvo file.
- Local-first: **no network calls in this library.** `swift` itself fetches the Norvo package; the code must not.
- Host-agnostic: nothing may mention Claude Code, OpenCode, or any single host; the data model is the only surface.
- **One Norvo Lite file per Musai library**, holding every project. Default location: `~/Library/Application Support/Musai/Musai.norvo`.
- The embedder is `qwen3-embedding-0.6b`, **1024 dimensions** (`§12`). No models are bundled; vector search is tested with hand-supplied vectors.
- Specs and plans are committed.
- Every mutation runs as a named `Actor`; history must record which one.

## Conventions

- **Tests come first.** Each task writes its test file before the production files it needs. Because the typed
  operations are generated from `.nql`, the first run fails to compile with `cannot find '<GeneratedType>' in
  scope` (or `cannot find 'MusaiLibrary' in scope`). That compile error *is* the red phase; then the production
  files go in and the test passes.
- Tests read generated results through **property access only** — never name a generated nested type. Codegen
  renames them when they clash with a schema or runtime name (`Task` → `Task_`), so the names are unstable.
- `#expect` never wraps `try await`; bind the value first, then assert.
- One test file per area, suites in Swift Testing, `swift test --filter <SuiteName>` for a single suite.

## Setup (once, before Task 1)

```sh
export MUSAI_NORVO_PATH=/Volumes/projects/Personal/norvo-swift   # needed when working from a git worktree
export NORVO_LOCAL=1                                            # use the engine built at ../NorvoDB/target/apple
```

`NORVO_LOCAL=1` makes the `norvo-swift` checkout use its `Artifacts/` symlinks (already pointed at
`NorvoDB/target/apple`) instead of downloading `binaries-v0.0.1`. Without it, `swift build` needs the network
once.

## Review Focus

The spec implies these inputs but no operation in section 6 names them. Each gets a test in the task that owns
its code.

1. **The same project re-bound from a second session** (same cwd, same remote) — one Project and one Session with
   that id, not a duplicate. → Task 3.
2. **The same repository reached by an SSH remote and an HTTPS remote** — both resolve to one Project. → Task 3.
3. **A Memory with no embedding**, searched by vector — skipped, not scored zero and not an error. → Task 8.
4. **Deleting an entity other entities point at** (a Plan that Tasks point at, a Link endpoint) — refs read
   `null`, lists and reverse-link queries do not fail. → Tasks 4 and 7.
5. **Non-ASCII and very long text** as a folder name or Memory text — the slug and the full-text search still
   behave. → Tasks 3, 5 and 8.

---

### Task 1: Package, codegen wiring, and the Project vertical slice

**Files:**
- Create: `Package.swift`, `README.md`
- Create: `Sources/MusaiCore/schema.nql`
- Create: `Sources/MusaiCore/migrations/0001_init.nql`
- Create: `Sources/MusaiCore/operations/fragments.nql`
- Create: `Sources/MusaiCore/operations/projects.nql`
- Create: `Sources/MusaiCore/MusaiActors.swift`
- Create: `Sources/MusaiCore/MusaiLibrary.swift`
- Test: `Tests/MusaiCoreTests/ProjectTests.swift`

**Interfaces:**
- Consumes: `NorvoLite` (`Database`, `Options`, `Actor`, `NorvoSchema.migrations`), from the NorvoLite package.
- Produces: `MusaiLibrary.open(at:options:) async throws -> MusaiLibrary`,
  `MusaiLibrary.inMemory(options:) async throws -> MusaiLibrary`, `MusaiLibrary.db: Database`,
  `MusaiLibrary.close()`, `MusaiLibrary.defaultFileURL: URL`; `MusaiActors.user/.curator/.migrator(_:)`;
  generated `ProjectBits`, `AllProjectsQuery`, `ProjectBySlugQuery`, `CreateProjectMutation`,
  `UpsertProjectMutation`, `SetProjectStatusMutation`, `DeleteProjectMutation`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.1
import Foundation
import PackageDescription

// Norvo Lite is under active development; point MUSAI_NORVO_PATH at a checkout (a worktree needs it).
let norvoPath = ProcessInfo.processInfo.environment["MUSAI_NORVO_PATH"] ?? "../norvo-swift"

let package = Package(
    name: "Musai",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MusaiCore", targets: ["MusaiCore"])],
    dependencies: [.package(path: norvoPath)],
    targets: [
        .target(
            name: "MusaiCore",
            dependencies: [.product(name: "NorvoLite", package: "norvo-swift")],
            exclude: ["schema.nql", "migrations", "operations"],
            plugins: [.plugin(name: "NorvoCodegen", package: "norvo-swift")]
        ),
        .testTarget(name: "MusaiCoreTests", dependencies: ["MusaiCore"])
    ]
)
```

- [ ] **Step 2: Write `Sources/MusaiCore/schema.nql` and its identical snapshot `migrations/0001_init.nql`**

`norvo check` requires `schema.nql` to equal the last migration; the plugin fails the build otherwise. Start
with Project only — Task 2 adds the rest.

```graphql
enum ProjectStatus { ACTIVE PAUSED DONE ARCHIVED }

type Project {
  name: String!
  slug: String! @unique
  status: ProjectStatus! @index
  summary: String @fulltext
  repoRemote: String @index
  rootPath: String @index
}
```

- [ ] **Step 3: Write `Sources/MusaiCore/operations/fragments.nql` and `operations/projects.nql`**

`fragments.nql`:

```graphql
fragment ProjectBits on Project {
  id
  name
  slug
  status
  summary
  repoRemote
  rootPath
  createdAt
  updatedAt
}
```

`projects.nql`:

```graphql
query AllProjects($first: Int = 200) {
  projects(orderBy: [{name: ASC}], first: $first) { ...ProjectBits }
}

query ProjectBySlug($slug: String!) {
  project(by: {slug: $slug}) { ...ProjectBits }
}

mutation CreateProject($name: String!, $slug: String!, $summary: String, $repoRemote: String, $rootPath: String) {
  createProject(input: {name: $name, slug: $slug, status: ACTIVE, summary: $summary, repoRemote: $repoRemote, rootPath: $rootPath}) { id }
}

mutation UpsertProject($name: String!, $slug: String!, $repoRemote: String, $rootPath: String) {
  upsertProject(by: {slug: $slug}, input: {name: $name, status: ACTIVE, repoRemote: $repoRemote, rootPath: $rootPath}) { id }
}

mutation SetProjectStatus($id: ID!, $status: ProjectStatus!) {
  updateProject(by: {id: $id}, set: {status: {set: $status}}) { id status }
}

mutation DeleteProject($id: ID!) {
  deleteProject(by: {id: $id})
}
```

Note the scalar-update shape: **every** scalar in a `set:` takes a `@oneOf` wrapper, so it is
`{status: {set: $status}}`, never `{status: $status}`. Relations in `set:` use `{connect: ...}` directly.

- [ ] **Step 4: Write the failing test `Tests/MusaiCoreTests/ProjectTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct ProjectTests {
    @Test func createsAndReadsAProject() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai", summary: "Workspace")),
            as: MusaiActors.user)
        let project = try await lib.db.query(ProjectBySlugQuery(.init(slug: "musai"))).project
        #expect(project?.name == "Musai")
        #expect(project?.status == .active)
        let all = try await lib.db.query(AllProjectsQuery()).projects
        #expect(all.map(\.slug) == ["musai"])
    }

    @Test func upsertIsIdempotent() async throws {
        let lib = try await MusaiLibrary.inMemory()
        for _ in 0..<2 {
            _ = try await lib.db.mutate(
                UpsertProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        }
        let all = try await lib.db.query(AllProjectsQuery()).projects
        #expect(all.count == 1)
    }

    @Test func aFileBackedLibrarySurvivesReopening() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-\(UUID().uuidString)/Musai.norvo")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try await MusaiLibrary.open(at: url)
        _ = try await first.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        first.close()
        let second = try await MusaiLibrary.open(at: url)
        let reopened = try await second.db.query(AllProjectsQuery()).projects
        #expect(reopened.count == 1)
        second.close()
    }
}
```

- [ ] **Step 5: Run the build — expect it to fail**

Run: `swift build`
Expected: FAIL — `cannot find 'MusaiLibrary' in scope`. The `.nql` files have already generated
`CreateProjectMutation`; the missing piece is the façade.

- [ ] **Step 6: Write `MusaiActors.swift` and `MusaiLibrary.swift`**

`MusaiActors.swift`:

```swift
import NorvoLite

/// The actors Musai writes as. History records these names, so they are stable strings.
public enum MusaiActors {
    public static let user = Actor(kind: .user, name: "user")
    public static let curator = Actor(kind: .agent, name: "curator")
    public static func migrator(_ name: String) -> Actor {
        Actor(kind: .system, name: "migration:\(name)")
    }
}
```

`MusaiLibrary.swift` — `open` always migrates, so no caller can forget; migrations are recorded by Lite, so
re-opening is a no-op.

```swift
import Foundation
import NorvoLite

/// A Musai library: the single Norvo Lite file holding every project.
public final class MusaiLibrary: Sendable {
    public let db: Database

    private init(db: Database) { self.db = db }

    public static func open(at url: URL, options: Options = .init()) async throws -> MusaiLibrary {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let library = MusaiLibrary(db: try Database.open(at: url, options: options))
        _ = try await library.db.migrate(NorvoSchema.migrations)
        return library
    }

    public static func inMemory(options: Options = .init()) async throws -> MusaiLibrary {
        let library = MusaiLibrary(db: try Database.inMemory(options: options))
        _ = try await library.db.migrate(NorvoSchema.migrations)
        return library
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Musai/Musai.norvo")
    }

    public func close() { db.close() }
}
```

- [ ] **Step 7: Run the tests — expect them to pass**

Run: `swift test --filter ProjectTests`
Expected: PASS, 3 tests.

- [ ] **Step 8: Write `README.md`**

Cover: what Musai is (one paragraph), the `MUSAI_NORVO_PATH` / `NORVO_LOCAL` setup above, and
`swift build` / `swift test`.

- [ ] **Step 9: Commit**

```bash
git add Package.swift README.md Sources Tests
git commit -m "feat: MusaiCore package on Norvo Lite with the Project slice"
```

---

### Task 2: The full graph schema

**Files:**
- Modify: `Sources/MusaiCore/schema.nql` (append the rest)
- Modify: `Sources/MusaiCore/migrations/0001_init.nql` (identical copy)
- Test: `Tests/MusaiCoreTests/SchemaTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: the schema types `Idea`, `Spec`, `Plan`, `Task`, `Decision`, `Memory`, `Session`, `WorkState`,
  `Link` and their enums; `Project`'s new `@inverse` fields. Every later task's operations depend on these exact
  names.

Nothing has shipped, so `0001_init.nql` is edited in place rather than followed by a second migration.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/SchemaTests.swift`**

```swift
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
        #expect(NorvoSchema.migrations.map(\.name) == ["0001_init"])
    }
}
```

- [ ] **Step 2: Run it — expect it to fail**

Run: `swift test --filter SchemaTests`
Expected: FAIL — the SDL does not contain `type Idea` and the rest.

- [ ] **Step 3: Replace `schema.nql` and `0001_init.nql` with the full SDL**

`Project` keeps the fields Task 1 gave it and gains its `@inverse` fields.

```graphql
enum ProjectStatus { ACTIVE PAUSED DONE ARCHIVED }
enum IdeaStatus { OPEN PROMOTED PARKED DROPPED }
enum SpecKind { REQUIREMENT DESIGN }
enum PlanStatus { DRAFT ACTIVE DONE }
enum TaskStatus { TODO DOING BLOCKED DONE }
enum MemoryKind { DECISION IDEA FACT PREFERENCE TODO LESSON }
enum MemoryOrigin { AUTHORED AMBIENT MIGRATED }
enum SessionStatus { ACTIVE COMPLETED FAILED }
enum LinkKind { DEPENDS_ON RELATES_TO SPAWNED DERIVED_FROM SUPERSEDES REFERENCES }

type Project {
  name: String!
  slug: String! @unique
  status: ProjectStatus! @index
  summary: String @fulltext
  repoRemote: String @index
  rootPath: String @index
  ideas: [Idea!]! @inverse(of: "project")
  specs: [Spec!]! @inverse(of: "project")
  plans: [Plan!]! @inverse(of: "project")
  tasks: [Task!]! @inverse(of: "project")
  memories: [Memory!]! @inverse(of: "project")
  decisions: [Decision!]! @inverse(of: "project")
  sessions: [Session!]! @inverse(of: "project")
}

type Idea {
  title: String!
  body: String @fulltext
  status: IdeaStatus! @index
  project: Project @index
  spawnedProject: Project
}

type Spec {
  title: String!
  kind: SpecKind! @index
  body: String @fulltext
  position: Int
  project: Project! @index
  plan: Plan @inverse(of: "spec")
}

type Plan {
  title: String!
  body: String @fulltext
  status: PlanStatus! @index
  project: Project! @index
  spec: Spec @index
  tasks: [Task!]! @inverse(of: "plan")
}

type Task {
  title: String!
  detail: String
  status: TaskStatus! @index
  position: Int
  project: Project! @index
  plan: Plan
}

type Decision {
  title: String!
  rationale: String @fulltext
  project: Project @index
  subject: Node
}

type Memory @plural(name: "memories") {
  kind: MemoryKind! @index
  origin: MemoryOrigin! @index
  text: String @fulltext
  narrative: String
  concepts: [String!]
  subject: Node
  provenance: String @index
  embedding: Vector @vector(dims: 1024, model: "qwen3-embedding-0.6b")
  project: Project @index
  session: Session @index
}

type Session {
  memorySessionId: String! @unique
  platform: String! @index
  cwd: String @index
  title: String
  status: SessionStatus! @index
  startedAt: DateTime! @index
  endedAt: DateTime
  project: Project @index
  memories: [Memory!]! @inverse(of: "session")
}

type WorkState @plural(name: "workStates") {
  project: Project! @index
  listName: String! @index
  fields: JSON
  origin: String @index
}

type Link {
  kind: LinkKind! @index
  source: Node
  target: Node
}
```

Design notes the implementer cannot infer:

- **`Link` is a plain entity type, not `@edge`.** It gives the same typed, queryable, history-bearing link with
  no `@relationship(through:)` machinery, and — the deciding reason — its `source`/`target` are nullable, so
  deleting a link's endpoint reads as `null` instead of putting `null` in a non-null position.
- **`Node`** is Norvo's built-in interface every type implements; a field typed `Node` is a stored ref to any
  entity. `Memory.subject` and `Decision.subject` are how a memory attaches to the thing it is about.
- Relations are stored on the child (`Plan.spec`, `Memory.project`, `Memory.session`), so the parent side
  declares `@inverse(of: "<child field>")` and stores nothing.
- Every generated root name (`projects`, `specs`, `memories`, `links`, …) comes from the type's plural, and every
  operation below spells it. `Memory` and `WorkState` pin theirs because their English plurals are the uncertain
  ones. If a build reports an unknown field for a plural, read the plural out of the SDL the build prints and
  pin it with `@plural(name:)` on that type — do not rename the operation.

- [ ] **Step 4: Run it — expect it to pass**

Run: `swift test --filter SchemaTests`
Expected: PASS. If the plugin rejects the SDL, the failure names `path:line:col`; fix the SDL, do not weaken the
test.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, all tests from Tasks 1 and 2.

- [ ] **Step 6: Commit**

```bash
git add Sources/MusaiCore/schema.nql Sources/MusaiCore/migrations Tests/MusaiCoreTests/SchemaTests.swift
git commit -m "feat: the Musai project graph schema"
```

---

### Task 3: Sessions and project binding

**Files:**
- Create: `Sources/MusaiCore/operations/sessions.nql`
- Create: `Sources/MusaiCore/ProjectBinder.swift`
- Test: `Tests/MusaiCoreTests/BindingTests.swift`

**Interfaces:**
- Consumes: the schema from Task 2; `MusaiLibrary`, `MusaiActors`.
- Produces: `ProjectBinder.gitRemote(for: URL) -> String?`, `.normalizedRemote(_: String) -> String`,
  `.bind(cwd:memorySessionId:platform:title:startedAt:as:) async throws -> BoundSession`,
  `BoundSession { id: UUID, memorySessionId: String, projectSlug: String }`; generated `ProjectByRemoteQuery`,
  `ProjectByRootQuery`, `SessionByMemoryIdQuery`, `UpsertSessionMutation`, `EndSessionMutation`, `SessionBits`.

- [ ] **Step 1: Write `operations/sessions.nql`**

```graphql
fragment SessionBits on Session {
  id
  memorySessionId
  platform
  cwd
  title
  status
  startedAt
  endedAt
}

query ProjectByRemote($remote: String!) {
  projects(where: {repoRemote: {eq: $remote}}, first: 1) { id slug name }
}

query ProjectByRoot($root: String!) {
  projects(where: {rootPath: {eq: $root}}, first: 1) { id slug name }
}

query SessionByMemoryId($memorySessionId: String!) {
  session(by: {memorySessionId: $memorySessionId}) { ...SessionBits }
}

mutation UpsertSession($memorySessionId: String!, $platform: String!, $cwd: String, $title: String, $startedAt: DateTime!, $slug: String!) {
  upsertSession(by: {memorySessionId: $memorySessionId}, input: {
    memorySessionId: $memorySessionId
    platform: $platform
    cwd: $cwd
    title: $title
    status: ACTIVE
    startedAt: $startedAt
    project: {connect: {slug: $slug}}
  }) { id }
}

mutation EndSession($memorySessionId: String!, $status: SessionStatus!, $endedAt: DateTime!) {
  updateSession(by: {memorySessionId: $memorySessionId}, set: {status: {set: $status}, endedAt: {set: $endedAt}}) { id status }
}
```

`connect` inside `input` takes any unique key, so binding writes the session in one call with no read of the
Project first.

- [ ] **Step 2: Write the failing test `Tests/MusaiCoreTests/BindingTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct BindingTests {
    /// A directory with a hand-written `.git/config`, so the test needs no `git`.
    private func makeRepo(name: String, remote: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-bind-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = \(remote)
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """.write(to: root.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func bindsIdempotently() async throws {
        let root = try makeRepo(name: "NorvoDB", remote: "git@github.com:NorvoDB/norvo-swift.git")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let lib = try await MusaiLibrary.inMemory()
        let binder = ProjectBinder(db: lib.db)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await binder.bind(cwd: root, memorySessionId: "s1", platform: "test", startedAt: start, as: MusaiActors.user)
        _ = try await binder.bind(cwd: root, memorySessionId: "s1", platform: "test", startedAt: start, as: MusaiActors.user)
        let projects = try await lib.db.query(AllProjectsQuery()).projects
        #expect(projects.count == 1)
        let session = try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "s1"))).session
        #expect(session?.memorySessionId == "s1")
    }

    @Test func normalizesRemotes() {
        let ssh = ProjectBinder.normalizedRemote("git@github.com:NorvoDB/norvo-swift.git")
        let https = ProjectBinder.normalizedRemote("https://github.com/NorvoDB/norvo-swift.git")
        #expect(ssh == https)
    }

    @Test func bindsTwoRemoteFormsToOneProject() async throws {
        let ssh = try makeRepo(name: "a", remote: "git@github.com:NorvoDB/norvo-swift.git")
        let https = try makeRepo(name: "b", remote: "https://github.com/NorvoDB/norvo-swift.git")
        defer {
            try? FileManager.default.removeItem(at: ssh.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: https.deletingLastPathComponent())
        }
        let lib = try await MusaiLibrary.inMemory()
        let binder = ProjectBinder(db: lib.db)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await binder.bind(cwd: ssh, memorySessionId: "s1", platform: "test", startedAt: start, as: MusaiActors.user)
        _ = try await binder.bind(cwd: https, memorySessionId: "s2", platform: "test", startedAt: start, as: MusaiActors.user)
        let projects = try await lib.db.query(AllProjectsQuery()).projects
        #expect(projects.count == 1)
    }

    @Test func aDirectoryWithoutGitBecomesItsOwnProject() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-bind-\(UUID().uuidString)/Sans-Dépôt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let lib = try await MusaiLibrary.inMemory()
        let binder = ProjectBinder(db: lib.db)
        let bound = try await binder.bind(
            cwd: root, memorySessionId: "s1", platform: "test",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), as: MusaiActors.user)
        let project = try await lib.db.query(ProjectBySlugQuery(.init(slug: bound.projectSlug))).project
        #expect(project?.name == "Sans-Dépôt")
        #expect(project?.rootPath == root.path)
    }
}
```

- [ ] **Step 3: Run it — expect it to fail**

Run: `swift test --filter BindingTests`
Expected: FAIL — `cannot find 'ProjectBinder' in scope`.

- [ ] **Step 4: Write `ProjectBinder.swift`**

```swift
import CryptoKit
import Foundation
import NorvoLite

public struct BoundSession: Sendable, Equatable {
    public let id: UUID
    public let memorySessionId: String
    public let projectSlug: String
}

/// Resolves a working directory to a Project and binds a Session to it.
public struct ProjectBinder: Sendable {
    public let db: Database
    public init(db: Database) { self.db = db }

    /// A remote in one canonical form, so an SSH clone and an HTTPS clone of one repository match.
    public static func normalizedRemote(_ remote: String) -> String {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.contains("://") {
            for scheme in ["https://", "http://", "ssh://", "git://"] where text.hasPrefix(scheme) {
                text.removeFirst(scheme.count)
                break
            }
            if text.hasPrefix("git@") { text.removeFirst(4) }
            return text
        }
        if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"), at < colon {
            let host = text[text.index(after: at)..<colon]
            let path = text[text.index(after: colon)...]
            return "\(host)/\(path)"
        }
        return text
    }

    /// Walks up from `cwd` for a repository and reads its `origin` URL. Handles a worktree's `.git` file.
    public static func gitRemote(for cwd: URL) -> String? { /* INNER */ }

    public func bind(cwd: URL, memorySessionId: String, platform: String, title: String? = nil,
                     startedAt: Date, as actor: Actor) async throws -> BoundSession { /* INNER */ }
}
```

Bodies the signature does not determine:

- `gitRemote(for:)`: walk `cwd` and its ancestors; at each, if `.git` is a directory read `.git/config`, if it
  is a file read it and follow its `gitdir:` line to `<path>/config`. In that config find the
  `[remote "origin"]` section's `url` value. Return `normalizedRemote(url)`, or `nil` when there is none.
- `bind(...)`: resolve the Project, then upsert the Session with its slug.
  1. `let remote = Self.gitRemote(for: cwd)`; if non-nil, `ProjectByRemoteQuery(.init(remote: remote))` and take
     `.projects.first`.
  2. Otherwise `ProjectByRootQuery(.init(root: cwd.path))` and take `.projects.first`.
  3. Otherwise choose `name = cwd.lastPathComponent` and `slug`: the lower-cased ASCII-alphanumeric-and-dash
     base of `name` (empty → `"project"`), when free; when taken, append `-` plus the first 8 lowercase hex
     characters of `SHA256(cwd.path)`. Deterministic, so re-binding a directory reuses its slug.
     Then `UpsertProjectMutation(name:slug:repoRemote:rootPath:)` with `cwd.path`.
  4. `UpsertSessionMutation` with the slug; its result carries the session's id, so build `BoundSession` from it
     with no read-back.

- [ ] **Step 5: Run the tests — expect them to pass**

Run: `swift test --filter BindingTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/MusaiCore/operations/sessions.nql Sources/MusaiCore/ProjectBinder.swift Tests/MusaiCoreTests/BindingTests.swift
git commit -m "feat: bind sessions to projects by working directory and git remote"
```

---

### Task 4: The SDD arc — ideas, specs, plans, tasks

**Files:**
- Create: `Sources/MusaiCore/operations/ideas.nql`, `specs.nql`, `plans.nql`, `tasks.nql`
- Test: `Tests/MusaiCoreTests/SDDTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 (`CreateProjectMutation`, `ProjectBySlugQuery`).
- Produces: generated `IdeaBits`, `AllIdeasQuery`, `IdeasForProjectQuery`, `CreateIdeaMutation`,
  `PromoteIdeaMutation`, `SpecBits`, `SpecsForProjectQuery`, `CreateSpecMutation`, `SetSpecBodyMutation`,
  `PlanBits`, `PlansForProjectQuery`, `CreatePlanMutation`, `LinkPlanToSpecMutation`, `SetPlanStatusMutation`,
  `DeletePlanMutation`, `TaskBits`, `TasksForPlanQuery`, `TasksForProjectByStatusQuery`, `CreateTaskMutation`,
  `SetTaskStatusMutation`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/SDDTests.swift`**

```swift
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
        #expect(specs.first?.plan?.id == plan)
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
```

- [ ] **Step 2: Run it — expect it to fail**

Run: `swift test --filter SDDTests`
Expected: FAIL — `cannot find 'CreateSpecMutation' in scope`.

- [ ] **Step 3: Write the four operation files**

`operations/ideas.nql`:

```graphql
fragment IdeaBits on Idea {
  id
  title
  body
  status
  createdAt
  project { slug }
  spawnedProject { slug }
}

query AllIdeas { ideas(orderBy: [{createdAt: ASC}]) { ...IdeaBits } }

query IdeasForProject($slug: String!) {
  ideas(where: {project: {slug: {eq: $slug}}}, orderBy: [{createdAt: ASC}]) { ...IdeaBits }
}

mutation CreateIdea($title: String!, $body: String, $slug: String!) {
  createIdea(input: {title: $title, body: $body, status: OPEN, project: {connect: {slug: $slug}}}) { id }
}

mutation PromoteIdea($id: ID!, $project: ID!) {
  updateIdea(by: {id: $id}, set: {status: {set: PROMOTED}, spawnedProject: {connect: {id: $project}}}) { id status }
}
```

`operations/specs.nql`:

```graphql
fragment SpecBits on Spec {
  id
  title
  kind
  body
  position
  createdAt
  project { slug }
  plan { id title }
}

query SpecsForProject($slug: String!) {
  specs(where: {project: {slug: {eq: $slug}}}, orderBy: [{position: ASC}, {createdAt: ASC}]) { ...SpecBits }
}

mutation CreateSpec($title: String!, $kind: SpecKind!, $body: String, $position: Int, $slug: String!) {
  createSpec(input: {title: $title, kind: $kind, body: $body, position: $position, project: {connect: {slug: $slug}}}) { id }
}

mutation SetSpecBody($id: ID!, $body: String!) {
  updateSpec(by: {id: $id}, set: {body: {set: $body}}) { id }
}
```

`operations/plans.nql`:

```graphql
fragment PlanBits on Plan {
  id
  title
  body
  status
  createdAt
  project { slug }
  spec { id title }
}

query PlansForProject($slug: String!) {
  plans(where: {project: {slug: {eq: $slug}}}, orderBy: [{createdAt: ASC}]) { ...PlanBits }
}

mutation CreatePlan($title: String!, $body: String, $slug: String!) {
  createPlan(input: {title: $title, body: $body, status: DRAFT, project: {connect: {slug: $slug}}}) { id }
}

mutation LinkPlanToSpec($plan: ID!, $spec: ID!) {
  updatePlan(by: {id: $plan}, set: {spec: {connect: {id: $spec}}}) { id }
}

mutation SetPlanStatus($id: ID!, $status: PlanStatus!) {
  updatePlan(by: {id: $id}, set: {status: {set: $status}}) { id status }
}

mutation DeletePlan($id: ID!) {
  deletePlan(by: {id: $id})
}
```

`operations/tasks.nql`:

```graphql
fragment TaskBits on Task {
  id
  title
  detail
  status
  position
  createdAt
  project { slug }
  plan { id title }
}

query TasksForPlan($plan: ID!) {
  tasks(where: {plan: {id: {eq: $plan}}}, orderBy: [{position: ASC}, {createdAt: ASC}]) { ...TaskBits }
}

query TasksForProjectByStatus($slug: String!, $status: TaskStatus!) {
  tasks(where: {project: {slug: {eq: $slug}}, status: {eq: $status}}, orderBy: [{position: ASC}]) { ...TaskBits }
}

mutation CreateTask($title: String!, $detail: String, $position: Int, $plan: ID!, $slug: String!) {
  createTask(input: {title: $title, detail: $detail, status: TODO, position: $position, project: {connect: {slug: $slug}}, plan: {connect: {id: $plan}}}) { id }
}

mutation SetTaskStatus($id: ID!, $status: TaskStatus!) {
  updateTask(by: {id: $id}, set: {status: {set: $status}}) { id status }
}
```

A relation that may be absent gets its own mutation rather than a nullable variable: `connect` with a null id
matches nothing and fails the call, which is why `LinkPlanToSpec` is separate from `CreatePlan`.

- [ ] **Step 4: Run it — expect it to pass**

Run: `swift test --filter SDDTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/operations Tests/MusaiCoreTests/SDDTests.swift
git commit -m "feat: the idea -> spec -> plan -> task arc"
```

---

### Task 5: Memories and decisions

**Files:**
- Create: `Sources/MusaiCore/operations/memories.nql`, `decisions.nql`
- Test: `Tests/MusaiCoreTests/MemoryTests.swift`

**Interfaces:**
- Consumes: Task 3's `UpsertSessionMutation`, Task 4's `CreateProjectMutation`.
- Produces: generated `MemoryBits`, `MemoriesForProjectQuery`, `MemoriesOfKindQuery`, `MemoryByProvenanceQuery`,
  `MemoryByIDQuery`, `RecordMemoryMutation`, `AttachMemoryToSubjectMutation`, `EmbedMemoryMutation`,
  `SetMemorySessionMutation`, `DeleteMemoryMutation`, `DecisionBits`, `DecisionsForProjectQuery`,
  `RecordDecisionMutation`, `AttachDecisionToSubjectMutation`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/MemoryTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct MemoryTests {
    private func seedProject(_ lib: MusaiLibrary) async throws -> UUID {
        try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user).createProject.id
    }

    @Test func memoriesAttachToTheThingTheyAreAbout() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let subject = try await seedProject(lib)
        let memory = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .decision, origin: .authored, text: "One Lite file", slug: "musai")),
            as: MusaiActors.user).createMemory.id
        _ = try await lib.db.mutate(
            AttachMemoryToSubjectMutation(.init(id: memory, subject: subject)), as: MusaiActors.user)

        let found = try await lib.db.query(MemoryByIDQuery(.init(id: memory))).memory
        #expect(found?.subject?.id == subject)
        #expect(found?.origin == .authored)
    }

    @Test func anAmbientMemoryCarriesProvenanceAndItsSession() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await seedProject(lib)
        _ = try await lib.db.mutate(
            UpsertSessionMutation(.init(
                memorySessionId: "s9", platform: "test",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), slug: "musai")),
            as: MusaiActors.curator)
        let memory = try await lib.db.mutate(
            RecordMemoryMutation(.init(
                kind: .fact, origin: .ambient, text: "the schema compiles",
                provenance: "event/42", slug: "musai")),
            as: MusaiActors.curator).createMemory.id
        _ = try await lib.db.mutate(
            SetMemorySessionMutation(.init(id: memory, memorySessionId: "s9")), as: MusaiActors.curator)

        let found = try await lib.db.query(MemoryByProvenanceQuery(.init(provenance: "event/42"))).memories
        #expect(found.first?.session?.memorySessionId == "s9")
    }

    @Test func emptyAndLongAndUnicodeTextRoundTrip() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await seedProject(lib)
        let long = String(repeating: "記憶 ", count: 2_000)
        _ = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .fact, origin: .authored, text: "", slug: "musai")),
            as: MusaiActors.user)
        _ = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .fact, origin: .authored, text: long, slug: "musai")),
            as: MusaiActors.user)
        let all = try await lib.db.query(MemoriesOfKindQuery(.init(kind: .fact))).memories
        #expect(all.count == 2)
        #expect(all.contains { $0.text == long })
    }

    @Test func decisionsAreAuthoredWithTheirRationale() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await seedProject(lib)
        let decision = try await lib.db.mutate(
            RecordDecisionMutation(.init(title: "One file", rationale: "Anti-clunk and anti-weight", slug: "musai")),
            as: MusaiActors.user).createDecision.id
        _ = try await lib.db.mutate(
            AttachDecisionToSubjectMutation(.init(id: decision, subject: decision)), as: MusaiActors.user)
        let decisions = try await lib.db.query(DecisionsForProjectQuery(.init(slug: "musai"))).decisions
        #expect(decisions.first?.title == "One file")
        #expect(decisions.first?.subject?.id == decision)
    }
}
```

- [ ] **Step 2: Run it — expect it to fail**

Run: `swift test --filter MemoryTests`
Expected: FAIL — `cannot find 'RecordMemoryMutation' in scope`.

- [ ] **Step 3: Write `operations/memories.nql`**

```graphql
fragment MemoryBits on Memory {
  id
  kind
  origin
  text
  narrative
  concepts
  provenance
  createdAt
  project { slug }
  session { id memorySessionId }
  subject { id }
}

query MemoriesForProject($slug: String!) {
  memories(where: {project: {slug: {eq: $slug}}}, orderBy: [{createdAt: DESC}]) { ...MemoryBits }
}

query MemoriesOfKind($kind: MemoryKind!) {
  memories(where: {kind: {eq: $kind}}, orderBy: [{createdAt: DESC}]) { ...MemoryBits }
}

query MemoryByProvenance($provenance: String!) {
  memories(where: {provenance: {eq: $provenance}}, first: 1) { ...MemoryBits }
}

query MemoryByID($id: ID!) {
  memory(by: {id: $id}) { ...MemoryBits embedding }
}

mutation RecordMemory($kind: MemoryKind!, $origin: MemoryOrigin!, $text: String, $narrative: String, $concepts: [String!], $provenance: String, $slug: String!) {
  createMemory(input: {
    kind: $kind
    origin: $origin
    text: $text
    narrative: $narrative
    concepts: $concepts
    provenance: $provenance
    project: {connect: {slug: $slug}}
  }) { id }
}

mutation AttachMemoryToSubject($id: ID!, $subject: ID!) {
  updateMemory(by: {id: $id}, set: {subject: {connect: {id: $subject}}}) { id }
}

mutation SetMemorySession($id: ID!, $memorySessionId: String!) {
  updateMemory(by: {id: $id}, set: {session: {connect: {memorySessionId: $memorySessionId}}}) { id }
}

mutation EmbedMemory($id: ID!, $embedding: Vector!) {
  updateMemory(by: {id: $id}, set: {embedding: {set: $embedding}}) { id }
}

mutation DeleteMemory($id: ID!) {
  deleteMemory(by: {id: $id})
}
```

`RecordMemory` and `AttachMemoryToSubject` are separate because `subject` is optional and `connect` with a null
id fails the call. The MCP layer later composes them into one authoring call inside a transaction.

- [ ] **Step 4: Write `operations/decisions.nql`**

```graphql
fragment DecisionBits on Decision {
  id
  title
  rationale
  createdAt
  project { slug }
  subject { id }
}

query DecisionsForProject($slug: String!) {
  decisions(where: {project: {slug: {eq: $slug}}}, orderBy: [{createdAt: DESC}]) { ...DecisionBits }
}

mutation RecordDecision($title: String!, $rationale: String, $slug: String!) {
  createDecision(input: {title: $title, rationale: $rationale, project: {connect: {slug: $slug}}}) { id }
}

mutation AttachDecisionToSubject($id: ID!, $subject: ID!) {
  updateDecision(by: {id: $id}, set: {subject: {connect: {id: $subject}}}) { id }
}
```

- [ ] **Step 5: Run it — expect it to pass**

Run: `swift test --filter MemoryTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/MusaiCore/operations Tests/MusaiCoreTests/MemoryTests.swift
git commit -m "feat: memories and decisions, authored and ambient"
```

---

### Task 6: Work-state lists

**Files:**
- Create: `Sources/MusaiCore/operations/workstate.nql`
- Test: `Tests/MusaiCoreTests/WorkStateTests.swift`

**Interfaces:**
- Consumes: Task 4's `CreateProjectMutation`.
- Produces: generated `WorkStateBits`, `WorkStateListsQuery`, `AddWorkStateEntryMutation`,
  `UpdateWorkStateEntryMutation`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/WorkStateTests.swift`**

```swift
import Foundation
import NorvoLite
import Testing
@testable import MusaiCore

@Suite struct WorkStateTests {
    @Test func listsAreScopedToAProjectAndKeepTheirShape() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "NorvoDB", slug: "norvo")), as: MusaiActors.user)
        _ = try await lib.db.mutate(
            AddWorkStateEntryMutation(.init(
                listName: "musai-work",
                fields: .object(["task": .string("write the schema"), "status": .string("doing")]),
                origin: "claude-mem", slug: "musai")),
            as: MusaiActors.migrator("claude-mem"))
        _ = try await lib.db.mutate(
            AddWorkStateEntryMutation(.init(listName: "other", fields: .null, slug: "norvo")),
            as: MusaiActors.migrator("claude-mem"))

        let lists = try await lib.db.query(WorkStateListsQuery(.init(slug: "musai"))).workStates
        #expect(lists.map(\.listName) == ["musai-work"])
        #expect(lists.first?.fields == .object(["task": .string("write the schema"), "status": .string("doing")]))
        #expect(lists.first?.origin == "claude-mem")
    }
}
```

- [ ] **Step 2: Run it — expect it to fail**

Run: `swift test --filter WorkStateTests`
Expected: FAIL — `cannot find 'AddWorkStateEntryMutation' in scope`.

- [ ] **Step 3: Write `operations/workstate.nql`**

```graphql
fragment WorkStateBits on WorkState {
  id
  listName
  fields
  origin
  createdAt
  project { slug }
}

query WorkStateLists($slug: String!) {
  workStates(where: {project: {slug: {eq: $slug}}}, orderBy: [{listName: ASC}, {createdAt: ASC}]) { ...WorkStateBits }
}

mutation AddWorkStateEntry($listName: String!, $fields: JSON!, $origin: String, $slug: String!) {
  createWorkState(input: {listName: $listName, fields: $fields, origin: $origin, project: {connect: {slug: $slug}}}) { id }
}

mutation UpdateWorkStateEntry($id: ID!, $fields: JSON!) {
  updateWorkState(by: {id: $id}, set: {fields: {set: $fields}}) { id }
}
```

`fields` is the one open-ended value in the model; `JSON` holds it without being indexed (NorvoQL `§3`), which
is what claude-mem's `work_state_entries.fields` blob needs.

- [ ] **Step 4: Run it — expect it to pass**

Run: `swift test --filter WorkStateTests`
Expected: PASS, 1 test.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/operations/workstate.nql Tests/MusaiCoreTests/WorkStateTests.swift
git commit -m "feat: work-state lists for claude-mem parity"
```

---

### Task 7: Typed links between entities

**Files:**
- Create: `Sources/MusaiCore/operations/links.nql`
- Test: `Tests/MusaiCoreTests/LinkTests.swift`

**Interfaces:**
- Consumes: Task 1's `CreateProjectMutation`, `DeleteProjectMutation`; Task 4's helpers.
- Produces: generated `LinkBits`, `OutgoingLinksQuery`, `IncomingLinksQuery`, `LinksOfKindQuery`,
  `CreateLinkMutation`, `DeleteLinkMutation`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/LinkTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct LinkTests {
    private func project(_ lib: MusaiLibrary, _ name: String, _ slug: String) async throws -> UUID {
        try await lib.db.mutate(
            CreateProjectMutation(.init(name: name, slug: slug)), as: MusaiActors.user).createProject.id
    }

    @Test func linksAreTypedAndReadableFromBothEnds() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let musai = try await project(lib, "Musai", "musai")
        let norvo = try await project(lib, "NorvoDB", "norvo")
        _ = try await lib.db.mutate(
            CreateLinkMutation(.init(source: musai, target: norvo, kind: .dependsOn)), as: MusaiActors.user)

        let out = try await lib.db.query(OutgoingLinksQuery(.init(id: musai))).links
        #expect(out.map(\.kind) == [.dependsOn])
        #expect(out.first?.target?.id == norvo)
        let incoming = try await lib.db.query(IncomingLinksQuery(.init(id: norvo))).links
        #expect(incoming.first?.source?.id == musai)
        let ofKind = try await lib.db.query(LinksOfKindQuery(.init(kind: .dependsOn))).links
        #expect(ofKind.count == 1)
    }

    @Test func deletingATargetLeavesTheLinkWithANullEndpoint() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let musai = try await project(lib, "Musai", "musai")
        let norvo = try await project(lib, "NorvoDB", "norvo")
        _ = try await lib.db.mutate(
            CreateLinkMutation(.init(source: musai, target: norvo, kind: .references)), as: MusaiActors.user)
        _ = try await lib.db.mutate(DeleteProjectMutation(.init(id: norvo)), as: MusaiActors.user)

        let out = try await lib.db.query(OutgoingLinksQuery(.init(id: musai))).links
        #expect(out.count == 1)
        #expect(out.first?.target?.id == nil)
        #expect(out.first?.source?.id == musai)
    }
}
```

- [ ] **Step 2: Run it — expect it to fail**

Run: `swift test --filter LinkTests`
Expected: FAIL — `cannot find 'CreateLinkMutation' in scope`.

- [ ] **Step 3: Write `operations/links.nql`**

```graphql
fragment LinkBits on Link {
  id
  kind
  createdAt
  source { id }
  target { id }
}

query OutgoingLinks($id: ID!) {
  links(where: {source: {id: {eq: $id}}}) { ...LinkBits }
}

query IncomingLinks($id: ID!) {
  links(where: {target: {id: {eq: $id}}}) { ...LinkBits }
}

query LinksOfKind($kind: LinkKind!) {
  links(where: {kind: {eq: $kind}}) { ...LinkBits }
}

mutation CreateLink($source: ID!, $target: ID!, $kind: LinkKind!) {
  createLink(input: {source: {connect: {id: $source}}, target: {connect: {id: $target}}, kind: $kind}) { id }
}

mutation DeleteLink($id: ID!) {
  deleteLink(by: {id: $id})
}
```

- [ ] **Step 4: Run it — expect it to pass**

Run: `swift test --filter LinkTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/operations/links.nql Tests/MusaiCoreTests/LinkTests.swift
git commit -m "feat: typed links and cross-project references"
```

---

### Task 8: Search — full text and vector

**Files:**
- Create: `Sources/MusaiCore/operations/search.nql`
- Test: `Tests/MusaiCoreTests/SearchTests.swift`

**Interfaces:**
- Consumes: Task 4's `CreateProjectMutation` and `CreateSpecMutation`, Task 5's `RecordMemoryMutation` and
  `EmbedMemoryMutation`.
- Produces: generated `SearchMemoriesQuery`, `SearchSpecsQuery`, `NearestMemoriesQuery`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/SearchTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct SearchTests {
    private func vector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 1024)
        v[axis] = 1
        return v
    }

    private func memory(_ lib: MusaiLibrary, _ text: String, embedding: [Float]? = nil) async throws -> UUID {
        let id = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .fact, origin: .authored, text: text, slug: "musai")),
            as: MusaiActors.user).createMemory.id
        if let embedding {
            _ = try await lib.db.mutate(EmbedMemoryMutation(.init(id: id, embedding: embedding)), as: MusaiActors.curator)
        }
        return id
    }

    private func seed(_ lib: MusaiLibrary) async throws {
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
    }

    @Test func fullTextSearchRanksByMatch() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        let hit = try await memory(lib, "copy on write btree pages")
        _ = try await memory(lib, "unrelated")
        let results = try await lib.db.query(SearchMemoriesQuery(.init(q: "copy on write"))).memoriesConnection.edges
        #expect(results.first?.node.id == hit)
        #expect((results.first?.score ?? 0) > 0)
    }

    @Test func unicodeAndPunctuationAreSearchable() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        let hit = try await memory(lib, "記憶 — the muses' sparks, idea → spec")
        let results = try await lib.db.query(SearchMemoriesQuery(.init(q: "記憶"))).memoriesConnection.edges
        #expect(results.first?.node.id == hit)
    }

    @Test func vectorSearchUsesCosineOrderAndSkipsUnembeddedMemories() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        let first = try await memory(lib, "near x", embedding: vector(0))
        let second = try await memory(lib, "near y", embedding: vector(1))
        let bare = try await memory(lib, "no embedding")

        let results = try await lib.db.query(NearestMemoriesQuery(.init(v: vector(0), k: 10))).memoriesConnection.edges
        let ids = results.map(\.node.id)
        #expect(ids.first == first)
        #expect(ids.contains(second))
        #expect(!ids.contains(bare))
    }

    @Test func specsAreSearchableByBody() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        _ = try await lib.db.mutate(
            CreateSpecMutation(.init(title: "Musai design", kind: .design, body: "one Lite file", position: 1, slug: "musai")),
            as: MusaiActors.user)
        let results = try await lib.db.query(SearchSpecsQuery(.init(q: "one Lite file"))).specsConnection.edges
        #expect(results.first?.node.title == "Musai design")
    }
}
```

- [ ] **Step 2: Run it — expect it to fail**

Run: `swift test --filter SearchTests`
Expected: FAIL — `cannot find 'SearchMemoriesQuery' in scope`.

- [ ] **Step 3: Write `operations/search.nql`**

```graphql
query SearchMemories($q: String!, $k: Int = 20, $first: Int = 20) {
  memoriesConnection(search: {text: {field: text, query: $q}, k: $k}, first: $first) {
    edges { score node { id kind text project { slug } } }
  }
}

query SearchSpecs($q: String!, $first: Int = 20) {
  specsConnection(search: {text: {field: body, query: $q}}, first: $first) {
    edges { score node { id title } }
  }
}

query NearestMemories($v: Vector!, $k: Int = 20) {
  memoriesConnection(search: {near: {field: embedding, vector: $v}, k: $k}) {
    edges { score node { id text } }
  }
}
```

Search goes through `...Connection`, whose edges carry `score`. `k` defaults to `first` when omitted.

- [ ] **Step 4: Run it — expect it to pass**

Run: `swift test --filter SearchTests`
Expected: PASS, 4 tests. If vector search returns the unembedded memory, the bug is in the query, not the engine.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/operations/search.nql Tests/MusaiCoreTests/SearchTests.swift
git commit -m "feat: full-text and vector memory search"
```

---

### Task 9: History and time travel

**Files:**
- Create: `Sources/MusaiCore/operations/history.nql`
- Test: `Tests/MusaiCoreTests/HistoryTests.swift`

**Interfaces:**
- Consumes: Task 4's `CreateSpecMutation`, `SetSpecBodyMutation`; Task 5's `RecordMemoryMutation`,
  `DeleteMemoryMutation`; `MusaiActors`.
- Produces: generated `SpecHistoryQuery`, `MemoryHistoryQuery`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/HistoryTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct HistoryTests {
    @Test func everyChangeNamesItsActorAndOldValue() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let spec = try await lib.db.mutate(
            CreateSpecMutation(.init(title: "Musai design", kind: .design, body: "first", position: 1, slug: "musai")),
            as: MusaiActors.user).createSpec.id
        _ = try await lib.db.mutate(
            SetSpecBodyMutation(.init(id: spec, body: "second")), as: MusaiActors.migrator("claude-mem"))

        let entries = try await lib.db.query(SpecHistoryQuery(.init(id: spec))).spec?.history.edges ?? []
        guard let latest = entries.first, entries.count >= 2 else {
            Issue.record("expected at least two history entries, got \(entries.count)")
            return
        }
        #expect(latest.node.fields.body?.new == "second")
        #expect(latest.node.fields.body?.old == "first")
        #expect(latest.node.actor.name == "migration:claude-mem")

        let authored = entries.last
        #expect(authored?.node.actor.name == "user")
        #expect(authored?.node.fields.body?.old != "second")
    }

    @Test func historyOfADeletedEntitySurvives() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let memory = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .decision, origin: .authored, text: "keep it", slug: "musai")),
            as: MusaiActors.user).createMemory.id
        _ = try await lib.db.mutate(DeleteMemoryMutation(.init(id: memory)), as: MusaiActors.user)

        let entries = try await lib.db.query(MemoryHistoryQuery(.init(id: memory))).memory?.history.edges ?? []
        #expect(!entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run it — expect it to fail**

Run: `swift test --filter HistoryTests`
Expected: FAIL — `cannot find 'SpecHistoryQuery' in scope`.

- [ ] **Step 3: Write `operations/history.nql`**

```graphql
query SpecHistory($id: ID!, $first: Int = 50) {
  spec(by: {id: $id}) {
    history(first: $first) {
      edges { node { at actor { name } kind fields { body { old new } } } }
    }
  }
}

query MemoryHistory($id: ID!, $first: Int = 50) {
  memory(by: {id: $id}) {
    history(first: $first) {
      edges { node { at actor { name } kind fields { text { old new } origin { old new } } } }
    }
  }
}
```

- [ ] **Step 4: Run it — expect it to pass**

Run: `swift test --filter HistoryTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, every suite.

- [ ] **Step 6: Commit**

```bash
git add Sources/MusaiCore/operations/history.nql Tests/MusaiCoreTests/HistoryTests.swift
git commit -m "feat: per-field history with its actor"
```

---

## What this plan leaves for the next one

- **Live queries.** `§7` and `§14` drive the app from Norvo Lite subscriptions, and `§15` says Musai does not
  re-test the engine. No `subscription` operation is needed yet; the app plan adds them over these same types.
- **The claude-mem import** (`§8` Migration, `§16.1` second half). It reads `~/.claude-mem/claude-mem.db` with
  the system `SQLite3` module and maps `sdk_sessions` → `Session`, `observations` → `Memory`,
  `session_summaries` → `Memory`/`Decision`, `work_state_entries` → `WorkState`, carrying embeddings where the
  dimensions match. It runs as `MusaiActors.migrator("claude-mem")`, so this plan's history tests already cover
  attribution. Task 5's `provenance` field exists to make the import idempotent.
- **Export into SDD tools** (`§9`, `§18`). Authored Specs and Plans leave for the repo; the format is undecided.
- The ingestion queue and host abstraction, MCP server, hooks and the connect handshake (`§10`, `§16.2`); the
  curator's model, prompt, throttle and filing rules (`§16.3`); the injection token budget and selection
  algorithm (`§18`); the SwiftUI workspace, viewer, model manager and backup (`§14`, `§16.4`); pruning
  claude-mem (`§16.5`); closed-loop automation (`§16.6`); and the concrete footprint numbers (`§18`).
