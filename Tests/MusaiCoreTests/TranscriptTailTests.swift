import Foundation
import Testing
@testable import musai

@Suite struct TranscriptTailTests {
    private func fixture(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-tail-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func theLastAssistantTextIsReturnedAndToolBlocksIgnored() throws {
        let url = try fixture([
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.swift"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"WHOLE FILE"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I changed a.swift"},{"type":"text","text":" and reran the tests."}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TranscriptTail.lastAssistantText(at: url, limit: 4_096) == "I changed a.swift and reran the tests.")
    }

    @Test func anUnknownFormatOrMissingFileIsNilNotAnError() throws {
        let missing = URL(fileURLWithPath: "/tmp/musai-nope-\(UUID().uuidString)")
        #expect(try TranscriptTail.lastAssistantText(at: missing) == nil)
        let url = try fixture(["not json at all"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TranscriptTail.lastAssistantText(at: url) == nil)
    }

    @Test func aHugeMessageIsTruncatedToTheLimit() throws {
        let big = String(repeating: "y", count: 20_000)
        let url = try fixture([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(big)"}]}}"#
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TranscriptTail.lastAssistantText(at: url, limit: 1_000)?.utf8.count == 1_000)
    }
}
