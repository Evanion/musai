import Foundation

/// One completion: a system prompt, a user message, and the JSON schema the answer must fit inside.
public protocol ModelProvider: Sendable {
    func complete(system: String, user: String, schema: Data) async throws -> String
}

/// The seam that keeps a test off the network.
public protocol ModelTransport: Sendable {
    func send(_ request: URLRequest, body: Data) async throws -> Data
}

public struct URLSessionTransport: ModelTransport {
    public init() {}

    public func send(_ request: URLRequest, body: Data) async throws -> Data {
        let (data, _) = try await URLSession.shared.upload(for: request, from: body)
        return data
    }
}
