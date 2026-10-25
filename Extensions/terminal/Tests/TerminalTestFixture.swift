import AppKit
import EdithExtensionSupport
@testable import TerminalExtension
import Testing

@MainActor enum TerminalTestFixture {
    static func engine(_ command: String = "exec cat") -> TerminalEngine {
        TerminalEngine {
            TerminalLaunch(
                executable: "/bin/sh", arguments: ["-c", command],
                environment: ["PATH=/usr/bin:/bin"],
                currentDirectory: "/private/tmp", startupCommand: nil)
        }
    }

    static func remote(_ engine: TerminalEngine) throws -> TerminalRemoteClient {
        let bridge = TerminalTestBridge(engine: engine)
        return TerminalRemoteClient(
            client: try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID())))
    }

    static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

    static func window(_ size: NSSize) -> NSWindow {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        return window
    }
}
