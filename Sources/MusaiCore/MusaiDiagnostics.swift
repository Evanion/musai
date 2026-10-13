import Foundation

/// What `musai doctor` prints, in one place and with no side effects: it is handed what was read — the
/// record, the `/health` payload when one answered, the log's tail, the bundle — and returns the whole
/// screen.
///
/// It exists to keep five states from being conflated, because a person's next move differs in each: the
/// agent has never run; it ran and the process that wrote the record is gone; it is alive but nothing
/// answers `/health`; `/health` answers; `/health` answers with a store that could not be opened. The last
/// two are what `.unreachable` alone cannot tell apart on the wire, which is exactly why they are told apart
/// here, out loud, with the log named.
public enum MusaiDiagnostics {
    /// The log this screen names, and the lines `doctor` reads at most. Both come from the log's own home
    /// rather than from a parameter: the path is a convention (the spec's §8), and naming anything else here
    /// would send a person to a file that is not the one they will find.
    public static let logPath = MusaiLog.defaultURL.path
    public static let logLines = 10

    /// The whole screen. `record` is what `HelperRecord.read` returned — nil when there is none; `health` is
    /// what `/health` answered — nil when nothing did, or was asked; `bundlePath` is where `Musai.app` was
    /// found — nil when it is not where `musai install` put it.
    public static func screen(
        record: HelperRecord?, health: EndpointHealth?, logTail: [String], bundlePath: URL?
    ) -> String {
        var lines = ["Musai backend"]

        // The record is the first fact, and the only one available when nothing ever ran: without it the
        // agent has never run here, and what a person needs is how to install it.
        guard let record else {
            lines.append(
                "the agent has never run on this Mac; there is no record of it at "
                    + HelperRecord.defaultURL.path)
            lines.append("install it once: musai install")
            lines.append("then look again: musai doctor")
            lines.append(contentsOf: bundleNote(bundlePath))
            return finish(lines, logTail: logTail)
        }

        // A record whose process is gone is not a running backend with a stale port: it is a process that
        // died, usually with the reason on its last lines.
        guard record.isAlive else {
            lines.append("the agent is not running (pid \(record.pid) is gone)")
            lines.append("the record it left names port \(record.port) and the store \(record.storePath)")
            lines.append("start it again: musai install")
            lines.append("or by hand: launchctl kickstart -k gui/$(id -u)/\(MusaiInstall.agentLabel)")
            lines.append(contentsOf: bundleNote(bundlePath))
            return finish(lines, logTail: logTail)
        }

        // Alive but silent: the state `.unreachable` cannot distinguish from a dead pid, and the one that
        // otherwise looks like "the backend is up" to anyone who only checks the process list.
        guard let health else {
            lines.append(
                "the agent is alive (pid \(record.pid)) but not answering /health on port \(record.port)")
            lines.append("it may still be starting, or it may be wedged; its last lines are below")
            lines.append("start it again: musai install")
            lines.append(contentsOf: bundleNote(bundlePath))
            return finish(lines, logTail: logTail)
        }

        // It answers. Everything a person needs to see that it works, and which build of it.
        lines.append("the agent is running (pid \(record.pid)) on port \(record.port)")
        lines.append("store: \(health.storePath) — \(storeText(health.storeState))")
        lines.append("uptime: up \(uptime(since: health.startedAt)) (since \(health.startedAt.formatted(.iso8601)))")
        lines.append("backlog: \(health.backlogDepth) waiting for the curator")
        lines.append("curator: \(health.curatorState.rawValue)")
        lines.append("protocol: \(health.protocolVersion)")
        lines.append(contentsOf: bundleNote(bundlePath))
        if health.storeState == .failed {
            // The amendment's point, said to the person: nothing else on this Mac can tell them why.
            lines.append("the store could not be opened, so nothing can be captured; \(logPath) names why")
        }
        return finish(lines, logTail: logTail)
    }

    /// How long the backend has been up, coarsely — a person checking whether it restarted a minute ago
    /// needs minutes, and the clock is the one thing here that moves.
    private static func uptime(since startedAt: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        return hours == 0 ? "\(minutes)m" : "\(hours)h \(minutes)m"
    }

    private static func storeText(_ state: StoreState) -> String {
        state == .open ? "open" : "could not be opened"
    }

    /// Where the bundle is, or that it is not where it was installed. The launch agent names the agent
    /// *inside* the bundle, so a missing bundle is why the agent never appears — and why an install has to
    /// be run again after the bundle moves.
    private static func bundleNote(_ bundlePath: URL?) -> [String] {
        guard let bundlePath else {
            return [
                "Musai.app is not where musai install put it; running musai install again puts it back",
                "moving or deleting Musai.app breaks the launch agent that starts the agent at login",
            ]
        }
        return ["bundle: \(bundlePath.path)"]
    }

    /// The tail, last, so the verdict is the first thing read and the evidence the last. Empty when there is
    /// nothing to show — not an empty heading.
    private static func finish(_ lines: [String], logTail: [String]) -> String {
        var out = lines
        out.append("")
        guard !logTail.isEmpty else {
            out.append("log (\(logPath)) is empty")
            return out.joined(separator: "\n")
        }
        out.append("log (\(logPath)), last \(logTail.count) lines:")
        out.append(contentsOf: logTail.map { "  \($0)" })
        return out.joined(separator: "\n")
    }
}
