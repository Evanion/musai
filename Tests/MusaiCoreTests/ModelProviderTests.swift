import Foundation
import Testing
@testable import MusaiCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(request: URLRequest, body: Data)] = []
    private let response: Data
    init(response: Data) { self.response = response }
    func record(_ request: URLRequest, body: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        seen.append((request, body))
        return response
    }
    var sent: [(request: URLRequest, body: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

private struct StubTransport: ModelTransport {
    let recorder: Recorder
    func send(_ request: URLRequest, body: Data) async throws -> Data {
        recorder.record(request, body: body)
    }
}

private func openAIResponse(_ content: String) -> Data {
    let object: [String: Any] = ["choices": [["message": ["content": content]]]]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func body(of data: Data) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

private let decisionsJSON = #"{"decisions":[{"title":"One Norvo file","rationale":"Anti-clunk","act":"DECISION","utterance_index":0}]}"#

@Suite struct ModelProviderTests {
    private func configured(_ recorder: Recorder) -> (OpenAICompatibleProvider, ModelConfiguration) {
        let configuration = ModelConfiguration.default
        return (OpenAICompatibleProvider(configuration: configuration, transport: StubTransport(recorder: recorder)), configuration)
    }

    @Test func theDefaultConfigurationRoundTripsThroughItsFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ModelConfiguration.default.write(to: url)
        #expect(try ModelConfiguration.load(from: url) == .default)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("apiKeyEnv") == false || text.contains("null"))
        #expect(ModelConfiguration.default.kind == .openAICompatible)
    }

    @Test func theProviderPostsAnOpenAICompatibleRequest() async throws {
        let recorder = Recorder(response: openAIResponse(decisionsJSON))
        let (provider, configuration) = configured(recorder)
        _ = try await provider.complete(system: "s", user: "u", schema: Data(#"{"type":"object"}"#.utf8))

        let sent = try #require(recorder.sent.first)
        #expect(sent.request.url?.path == "/v1/chat/completions")
        let json = body(of: sent.body)
        #expect(json["model"] as? String == configuration.model)
        #expect(json["stream"] as? Bool == false)
        let format = json["response_format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
    }

    /// The plan's number for the model path — 60 s, under the host's 120 s — is the number that reaches the
    /// wire, and a person who edits `timeoutSeconds` gets exactly that on the request. Nothing here leans on
    /// `URLSession`'s own default, which would be a coincidence rather than the plan's decision.
    @Test func theModelRequestCarriesTheConfiguredTimeout() async throws {
        let recorder = Recorder(response: openAIResponse(decisionsJSON))
        let (provider, configuration) = configured(recorder)
        _ = try await provider.complete(system: "s", user: "u", schema: Data(#"{"type":"object"}"#.utf8))

        let sent = try #require(recorder.sent.first)
        #expect(sent.request.timeoutInterval == configuration.timeoutSeconds)
        #expect(ModelConfiguration.default.timeoutSeconds == 60)

        // An edited file is what the client sends, not what the default happens to be.
        let edited = Recorder(response: openAIResponse(decisionsJSON))
        var shorter = ModelConfiguration.default
        shorter.timeoutSeconds = 12
        let providerWithShorter = OpenAICompatibleProvider(
            configuration: shorter, transport: StubTransport(recorder: edited))
        _ = try await providerWithShorter.complete(system: "s", user: "u", schema: Data(#"{"type":"object"}"#.utf8))
        #expect(try #require(edited.sent.first).request.timeoutInterval == 12)
    }

    @Test func aKeyComesFromTheEnvironmentAndIsNeverStored() async throws {
        let recorder = Recorder(response: openAIResponse("{}"))
        var configuration = ModelConfiguration.default
        configuration.apiKeyEnv = "MUSAI_TEST_KEY"
        setenv("MUSAI_TEST_KEY", "sk-not-in-the-file", 1)
        defer { unsetenv("MUSAI_TEST_KEY") }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-key-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try configuration.write(to: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("sk-not-in-the-file") == false)

        let provider = OpenAICompatibleProvider(
            configuration: configuration, transport: StubTransport(recorder: recorder))
        _ = try await provider.complete(system: "s", user: "u", schema: Data(#"{"type":"object"}"#.utf8))
        let sent = try #require(recorder.sent.first)
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-not-in-the-file")
    }

    private func detected(_ count: Int) -> [DetectedEvent] {
        (0..<count).map { index in
            DetectedEvent(
                id: UUID(), kind: .userTurn, text: "turn \(index)", tool: nil, target: nil,
                at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), utterance: UUID())
        }
    }

    @Test func itParsesDecisionsFromTheModelsJSON() async throws {
        let recorder = Recorder(response: openAIResponse(decisionsJSON))
        let events = detected(1)
        let detector = ModelDecisionDetector(provider: configured(recorder).0)
        let proposals = try await detector.propose(from: events)

        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "One Norvo file")
        #expect(proposals.first?.rationale == "Anti-clunk")
        #expect(proposals.first?.act == .decision)
        #expect(proposals.first?.utterance == events[0].utterance)
    }

    @Test func invalidJSONFromTheModelProposesNothing() async throws {
        let recorder = Recorder(response: openAIResponse("I think maybe one decision?"))
        let detector = ModelDecisionDetector(provider: configured(recorder).0)
        #expect(try await detector.propose(from: detected(1)).isEmpty)
    }

    @Test func aHallucinatedUtteranceIndexIsDroppedNotCrashing() async throws {
        let recorder = Recorder(response: openAIResponse(#"{"decisions":[{"title":"T","act":"DECISION","utterance_index":99}]}"#))
        let detector = ModelDecisionDetector(provider: configured(recorder).0)
        let proposals = try await detector.propose(from: detected(1))
        #expect(proposals.count == 1)
        #expect(proposals.first?.utterance == nil)
    }

    @Test func anEmptyEventListDoesNotCallTheProvider() async throws {
        let recorder = Recorder(response: openAIResponse("{}"))
        let detector = ModelDecisionDetector(provider: configured(recorder).0)
        #expect(try await detector.propose(from: []).isEmpty)
        #expect(recorder.sent.isEmpty)
    }
}
