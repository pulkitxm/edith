@testable import HerdrUI
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct HerdrServerStartupTests {
    @Test func discoveryReportsAStoppedSessionWithoutStartingOrOwningItsServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("herdr")
        let calls = directory.appendingPathComponent("calls")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> \(ShellQuote.quote(calls.path))
            if [ "$1" = session ]; then
                printf '%s\\n' '{"sessions":[{"name":"example"}]}'
                exit 0
            fi
            printf '%s\\n' '{"error":{"code":"server_not_running","message":"server stopped"}}' >&2
            exit 1
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let snapshot = await HerdrCollector.collectLocal(executable: executable)

        #expect(snapshot.herdrPresent)
        #expect(snapshot.agents.isEmpty)
        #expect(snapshot.error == "server stopped")
        let commands = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(
            String.init)
        #expect(
            commands == [
                "session list --json", "--session example api snapshot",
                "--session example agent list",
            ])
    }

    @Test func discoveryDoesNotLaunchAnythingWhenHerdrIsUnavailable() async {
        let snapshot = await HerdrCollector.collectLocal(executable: nil)
        #expect(!snapshot.herdrPresent)
        #expect(snapshot.agents.isEmpty)
        #expect(snapshot.error == "herdr is not on PATH")
    }
}
