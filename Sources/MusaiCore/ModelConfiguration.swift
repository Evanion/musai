import Foundation

/// How the curator reaches a model. Embedded (MLX), local (LM Studio, vLLM, Ollama, llama.cpp) and cloud
/// (Anthropic, OpenAI, Ollama Cloud) are one shape — a system prompt in, JSON out — so this is configuration,
/// never a code path.
public struct ModelConfiguration: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case openAICompatible
        case anthropic
        case mlx
    }

    public var kind: Kind
    public var baseURL: String
    public var model: String
    /// The *name* of the environment variable holding a cloud key. The key itself is never written down.
    public var apiKeyEnv: String?
    /// In seconds: a file a person may hand-edit should hold a plain number.
    public var timeoutSeconds: Double
    public var maxTokens: Int

    public static let `default` = ModelConfiguration(
        kind: .openAICompatible,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "qwen3.6:27b",
        apiKeyEnv: nil,
        timeoutSeconds: 120,
        maxTokens: 2_048)

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Musai/config.json")
    }

    /// Writes the default when the file is absent, and falls back to it when the file cannot be read: a broken
    /// config must not stop the loop.
    public static func load(from url: URL = defaultFileURL) throws -> ModelConfiguration {
        if !FileManager.default.fileExists(atPath: url.path) {
            try `default`.write(to: url)
            return `default`
        }
        guard let data = try? Data(contentsOf: url),
            let configuration = try? JSONDecoder().decode(ModelConfiguration.self, from: data)
        else { return `default` }
        return configuration
    }

    public func write(to url: URL = defaultFileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    /// The key, read from the environment at the moment it is needed and never stored.
    public var apiKey: String? {
        guard let name = apiKeyEnv, !name.isEmpty else { return nil }
        let value = ProcessInfo.processInfo.environment[name]
        return (value?.isEmpty ?? true) ? nil : value
    }
}
