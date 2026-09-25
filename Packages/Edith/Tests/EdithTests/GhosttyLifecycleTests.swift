import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyLifecycleTests {
    @Test @MainActor func closingWithALiveProcessDoesNotRequireConfirmation() async {
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        var exitCodes: [Int32?] = []
        view.onClose = { exitCodes.append($0) }

        view.reportClosed(processAlive: true)
        await Task.yield()

        #expect(exitCodes.count == 1)
        #expect(exitCodes[0] == nil)
    }

    @Test @MainActor func anEmptyFrameDuringRehostingKeepsTheTerminalGrid() throws {
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(
                executable: "/bin/sh", arguments: ["-c", "cat"], environment: environment))
        defer {
            view.removeFromSuperview()
            window.contentView = nil
            view.shutdown()
        }
        let pane = NSSize(width: 446, height: 303)
        window.contentView = NSView(frame: window.contentLayoutRect)
        view.frame = NSRect(origin: .zero, size: pane)
        window.contentView?.addSubview(view)
        let surface = try #require(view.surface)
        let laidOut = ghostty_surface_size(surface)

        view.setFrameSize(.zero)
        let collapsed = ghostty_surface_size(surface)
        view.setFrameSize(pane)
        let restored = ghostty_surface_size(surface)

        #expect(laidOut.columns > 10)
        #expect(collapsed.columns == laidOut.columns)
        #expect(collapsed.rows == laidOut.rows)
        #expect(restored.columns == laidOut.columns)
        #expect(restored.rows == laidOut.rows)
    }

    @Test @MainActor func anExitedChildCannotCloseTheSurfaceThatReusesItsSlot() async throws {
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))

        for _ in 0..<8 {
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("edith-ghostty-exit-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }
            let exiting = GhosttyTerminalView(
                launch: GhosttyLaunch(
                    executable: "/bin/sh", arguments: ["-c", "echo done > '\(marker.path)'"],
                    environment: environment))
            exiting.frame = window.contentLayoutRect
            window.contentView = exiting
            _ = try #require(exiting.surface)
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                usleep(5_000)
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            usleep(200_000)
            window.contentView = nil
            exiting.shutdown()

            let replacement = GhosttyTerminalView(
                launch: GhosttyLaunch(
                    executable: "/bin/sh", arguments: ["-c", "cat"], environment: environment))
            replacement.frame = window.contentLayoutRect
            window.contentView = replacement
            _ = try #require(replacement.surface)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(replacement.surface != nil)
            window.contentView = nil
            replacement.shutdown()
        }
    }
}
