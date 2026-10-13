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

/// Renders the backend's status into the menu-bar item. Driven by `EndpointState`'s change notification, not a
/// timer: `render` is called only when the state actually changes, so an idle agent does no work on the item.
private final class StatusPresenter: NSObject, @unchecked Sendable {
    private let item: NSStatusItem
    private let line: NSMenuItem
    private let lock = NSLock()
    private var shown = ""

    init(item: NSStatusItem, line: NSMenuItem) {
        self.item = item
        self.line = line
    }

    /// Called from the state's observer, on whichever thread mutated the state. A status item may only be
    /// touched on the main thread, so the write hops to the main queue — which the running run loop drains.
    func render(_ text: String) {
        lock.lock()
        let changed = text != shown
        if changed { shown = text }
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [self] in
            item.button?.title = "Musai: \(text)"
            line.title = text
        }
    }
}

/// One menu item's target: Quit.
@MainActor
private final class QuitTarget: NSObject {
    /// A single instance held for the process's life. `NSMenuItem.target` is a *weak* reference, so a
    /// function-local target would be deallocated and clicking Quit would silently do nothing.
    static let shared = QuitTarget()
    @objc func quit(_ sender: Any?) { bootOutAndExit() }
}

/// Builds the menu-bar item and runs the app. Called from the synchronous top level (no `await` before it), so
/// the process has a plain `main`.
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
    quitItem.target = QuitTarget.shared
    menu.addItem(quitItem)
    statusItem.menu = menu

    let presenter = StatusPresenter(item: statusItem, line: statusLine)

    // The item is driven by the state, not a timer. The observer is registered before `start()` so no change
    // can land before anyone is listening, and `start()` runs off the main actor while the run loop runs. A
    // requested restart ends the process, which is the whole point of `KeepAlive`.
    Task.detached {
        await agent.state.observeStatus { text in
            presenter.render(text)
            if text == "needsRestart" { exit(0) }
        }
        do {
            _ = try await agent.start()
        } catch {
            // A store already held, or a listener that cannot bind: one line, non-zero, and launchd decides.
            fail("\(error)")
        }
        presenter.render(await agent.statusText())
    }

    app.run()
    exit(0)
}

// Synchronous top level: the store is opened inside the run loop's task above, so there is no `await` here and
// the process has a plain `main`. Deliberate — with top-level `await` (an async main) the main actor stays
// occupied by `NSApplication.run()`, and neither main-actor tasks nor main-queue blocks resume, so the status
// item's updates would never be applied. Reproduced with a standalone AppKit script.
let arguments = Array(CommandLine.arguments.dropFirst())
let store = libraryURL(from: arguments)

let agent: MusaiAgent
do {
    // The producer is turned on here, where the one process that owns the store decides what it runs: without
    // it the graph only grows by import and by hand, and claude-mem cannot be switched off.
    agent = try MusaiAgent(
        libraryURL: store,
        filer: ModelMemoryFiler(configuration: (try? ModelConfiguration.load()) ?? .default))
} catch {
    fail("\(error)")
}

runStatusItem(agent: agent)
