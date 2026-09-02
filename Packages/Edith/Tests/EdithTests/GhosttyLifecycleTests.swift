import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyLifecycleTests {
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
