import Foundation
import Testing
@testable import MusaiCore

@Suite struct CaptureTests {
    private func library() async throws -> MusaiLibrary {
        try await MusaiLibrary.inMemory()
    }

    @Test func aUserTurnIsStoredVerbatimAndCapped() async throws {
        let lib = try await library()
        let capture = MusaiCapture(db: lib.db)
        _ = try await capture.captureUserTurn(
            text: "I said that I want to Read the post", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: "/tmp/musai-capture", as: MusaiActors.curator)
        let long = String(repeating: "x", count: MusaiCapture.maxTextBytes + 5_000)
        _ = try await capture.captureUserTurn(
            text: long, at: Date(timeIntervalSince1970: 1_700_000_001),
            origin: "claude", session: "s1", cwd: "/tmp/musai-capture", as: MusaiActors.curator)

        let rows = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.count == 2)
        #expect(rows.first?.text == "I said that I want to Read the post")
        #expect(rows.last?.text.utf8.count == MusaiCapture.maxTextBytes)
    }

    @Test func aToolUseStoresItsReferenceAndNeverItsResult() async throws {
        let lib = try await library()
        let capture = MusaiCapture(db: lib.db)
        _ = try await capture.captureToolUse(
            tool: "Edit", target: "Sources/MusaiCore/ProjectBinder.swift", digest: "sha256:abc",
            at: Date(timeIntervalSince1970: 1_700_000_000), session: "s1", cwd: "/tmp/musai-capture",
            as: MusaiActors.curator)

        let events = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(events.count == 1)
        #expect(events.first?.kind == .toolUse)
        #expect(events.first?.tool == "Edit")
        #expect(events.first?.target == "Sources/MusaiCore/ProjectBinder.swift")
        #expect(events.first?.text == nil)
    }

    @Test func theSameTurnCapturedTwiceIsOneRow() async throws {
        let lib = try await library()
        let capture = MusaiCapture(db: lib.db)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<2 {
            _ = try await capture.captureUserTurn(
                text: "same words", at: at, origin: "claude", session: "s1",
                cwd: "/tmp/musai-capture", as: MusaiActors.curator)
        }
        let rows = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.count == 1)
    }
}
