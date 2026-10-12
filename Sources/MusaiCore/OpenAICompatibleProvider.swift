import Foundation

/// Every local server in the list — Ollama, LM Studio, vLLM, llama.cpp — exposes `/v1/chat/completions`, so one
/// provider reaches them all. Anthropic and MLX come later behind the same protocol, and nothing above this
/// line changes when they do.
public struct OpenAICompatibleProvider: ModelProvider {
    public let configuration: ModelConfiguration
    public let transport: any ModelTransport

    public init(configuration: ModelConfiguration, transport: any ModelTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func complete(system: String, user: String, schema: Data) async throws -> String {
        let base = configuration.baseURL.hasSuffix("/")
            ? String(configuration.baseURL.dropLast())
            : configuration.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw Failure.badBaseURL }

        let shape = (try? JSONSerialization.jsonObject(with: schema)) ?? ["type": "object"]
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0,
            "stream": false,
            "max_tokens": configuration.maxTokens,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "decisions", "strict": true, "schema": shape],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let data = try await transport.send(request, body: JSONSerialization.data(withJSONObject: body))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw Failure.unreadableResponse }
        return content
    }

    public enum Failure: Error {
        case badBaseURL
        case unreadableResponse
    }
}
