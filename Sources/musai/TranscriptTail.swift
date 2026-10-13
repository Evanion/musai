import Foundation
import MusaiCore

/// The one transcript read in the system: the agent's own last message, from the file the host's `Stop` hook
/// hands over. Only `text` blocks are taken — never a tool call, never a tool's result — and only the tail of
/// the file is read. A format change degrades to `nil`, never to an error.
public enum TranscriptTail {
    /// At most this much of the end of the file is read.
    public static let maxTailBytes = 1 << 20

    public static func lastAssistantText(at url: URL, limit: Int = MusaiCapture.maxTextBytes) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let truncated = size > UInt64(maxTailBytes)
        let start = truncated ? size - UInt64(maxTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }

        var lines = Array(data.split(separator: 0x0A))
        // When the read began mid-file, the first line is a fragment of one.
        if truncated, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            let texts = content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }
            return MusaiCapture.truncated(texts.joined(separator: " "), to: limit)
        }
        return nil
    }
}
