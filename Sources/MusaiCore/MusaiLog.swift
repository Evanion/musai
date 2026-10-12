import Foundation

/// The log a person reads: one file, written by the agent alone, bounded so it can be opened by hand and
/// still end with what just happened.
///
/// The bound is counted in lines rather than bytes because a line is the unit a person reads, and 2 000 of
/// them hold a startup, a store that would not open, and a restart — which is the whole of what `musai
/// doctor` is asked to explain. The file is trimmed on write, so it is never bigger than its bound.
public struct MusaiLog: Sendable {
    /// `~/Library/Logs/Musai/helper.log`, under the same Library as the record — the path the spec's §8
    /// names, and the one a person sees there.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Musai/helper.log")
    }

    public let url: URL
    /// How many lines survive a write.
    public let limit: Int

    /// Guarded because the agent writes from several tasks — the start, the status changes, the drain — and
    /// two lines must not interleave into one.
    private let lock = NSLock()

    /// - Parameters:
    ///   - url: where the log goes. Injectable the same way the store is, so a test does not write into the
    ///     developer's real `~/Library/Logs/Musai`.
    ///   - limit: the plan's 2 000 lines.
    public init(url: URL = MusaiLog.defaultURL, limit: Int = 2_000) {
        self.url = url
        self.limit = max(1, limit)
    }

    /// Appends one line, trimming the file to its last `limit` lines, and creates the directory when it is
    /// not there yet. It never throws: a log that cannot be written must not be the reason a backend cannot
    /// start, and the next line is more useful than an error about the last one.
    public func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = read()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    /// The last `lines` lines, oldest first — fewer when the log holds fewer, and none when it is not there.
    public func tail(_ lines: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(read().suffix(max(0, lines)))
    }

    /// One line with the time it happened, which is the first thing a person looks for in a log. ISO 8601,
    /// so what the log shows and what the wire carries agree.
    public static func line(_ message: String, at date: Date = Date()) -> String {
        "\(date.formatted(.iso8601)) \(message)"
    }

    /// The file's lines. The newline that ends the last line does not count as a line of its own, so a log of
    /// one line reads back as one line rather than two.
    private func read() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
