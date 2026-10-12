import AppKit
import Darwin
import Foundation
import MusaiCore

/// The launch agent's label. `musai install` writes the job under this name; Quit boots it out, because the
/// plist's `KeepAlive` would otherwise bring the agent straight back.
private let agentLabel = "dev.musai.agent"

/// The store this agent serves: `--library`, then `MUSAI_LIBRARY`, then the one place a person installs to.
private func libraryURL(from arguments: [String]) -> URL {
    if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1])
    }
    if let environment = ProcessInfo.processInfo.environment["MUSAI_LIBRARY"], !environment.isEmpty {
        return URL(fileURLWithPath: environment)
    }
    return MusaiLibrary.defaultFileURL
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("musai-agent: \(message)\n".utf8))
    exit(1)
}

/// Quit: ask launchd to stop the job and keep it stopped, then end. Started by hand, `bootout` fails
/// harmlessly and the process simply exits — which is also "stays quit", because nothing owns it.
private func bootOutAndExit() -> Never {
    let launchctl = Process()
    launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    launchctl.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
    try? launchctl.run()
    launchctl.waitUntilExit()
    exit(0)
}

/// Redraws the status item from the backend's own state on a short, nearly free timer, and only when the
/// text changes — the store is never touched here, so an idle agent does no work beyond a memory read.
/// A pending restart ends the process, which is the whole point of `KeepAlive`.
///
/// The read runs off the main actor, and the update hops back through `RunLoop.main.perform`. Observed while
/// building this: `NSApplication.run()` occupies the main actor so a main-actor `Task` never resumes, and the
/// main dispatch queue is not drained either — only the run loop's own block source runs. Using whichever is
/// drained, rather than the obvious one, is what keeps the title from sitting at "starting".
private final class StatusTicker: NSObject, @unchecked Sendable {
    private let agent: MusaiAgent
    private let item: NSStatusItem
    private let line: NSMenuItem
    /// Touched only on the main queue.
    private var shown = ""

    init(agent: MusaiAgent, item: NSStatusItem, line: NSMenuItem) {
        self.agent = agent
        self.item = item
        self.line = line
    }

    @objc func tick() {
        Task.detached { [self] in
            if await agent.restartRequested() { exit(0) }
            let text = await agent.statusText()
            RunLoop.main.perform {
                guard text != self.shown else { return }
                self.shown = text
                self.item.button?.title = "Musai: \(text)"
                self.line.title = text
            }
        }
    }
}

/// One menu item's target: Quit. It is held by the app for the process's life.
@MainActor
private final class QuitTarget: NSObject {
    @objc func quit(_ sender: Any?) { bootOutAndExit() }
}

/// Builds the menu-bar item and runs the app. Synchronous, so the timer is scheduled on the run loop that is
/// about to run rather than inside a suspension.
@MainActor
private func runStatusItem(agent: MusaiAgent) -> Never {
    let app = NSApplication.shared
    // `LSUIElement` in the nested bundle's plist keeps this out of the Dock; the policy is belt and braces for
    // a binary run straight out of `.build`.
    app.setActivationPolicy(.accessory)

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "Musai: starting"

    let menu = NSMenu()
    let statusLine = NSMenuItem(title: "starting", action: nil, keyEquivalent: "")
    statusLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(.separator())
    let quitItem = NSMenuItem(
        title: "Quit Musai", action: #selector(QuitTarget.quit(_:)), keyEquivalent: "q")
    let quitTarget = QuitTarget()
    quitItem.target = quitTarget
    menu.addItem(quitItem)
    statusItem.menu = menu

    let ticker = StatusTicker(agent: agent, item: statusItem, line: statusLine)
    Timer.scheduledTimer(
        timeInterval: 1.5, target: ticker, selector: #selector(StatusTicker.tick), userInfo: nil,
        repeats: true)

    app.run()
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let store = libraryURL(from: arguments)

let agent: MusaiAgent
do {
    agent = try MusaiAgent(libraryURL: store)
} catch {
    fail("\(error)")
}

do {
    _ = try await agent.start()
} catch {
    // A store already held, or a listener that cannot bind: one line, non-zero, and launchd decides.
    fail("\(error)")
}

runStatusItem(agent: agent)
