import EdithExtensionSupport
import Foundation
import Testing
@testable import EdithHostCore

@Suite struct HostCLITests {
    @Test func calendarForwardsContextAndPreservesOriginalChannelsWithoutReadingStdin() throws {
        let originalDirectory = FileManager.default.currentDirectoryPath
        let input = Data("synthetic input".utf8)
        var stdout = Data()
        var stderr = Data()
        let code = HostCLI.run(
            ["calendar", "ls", "--json"],
            invoke: { request in
                let context = try JSONDecoder().decode(
                    ExtensionCLIRequest.self, from: request.payload)
                #expect(context.arguments == ["ls", "--json"])
                #expect(context.workingDirectory == "/tmp/synthetic-caller")
                #expect(context.standardInput == input && context.interactive)
                return try JSONEncoder().encode(
                    ExtensionCLIReply(
                        stdout: "synthetic no newline", stderr: "diagnostic\n", exitCode: 130))
            }, standardInput: input, workingDirectory: "/tmp/synthetic-caller", interactive: true,
            readInput: { throw HostCLIError.rejected("stdin must not be read") }
        ) { data, error in
            if error { stderr.append(data) } else { stdout.append(data) }
        }
        #expect(code == 130)
        #expect(stdout == Data("synthetic no newline".utf8))
        #expect(stderr == Data("diagnostic\n".utf8))
        #expect(FileManager.default.currentDirectoryPath == originalDirectory)
    }

    @Test func malformedTerminalResultDoesNotEmitAnyClaimedOutput() {
        for value in [
            "not JSON", "{\"stdout\":\"synthetic untrusted\",\"stderr\":\"\",\"exitCode\":256}",
        ] {
            var stdout = Data()
            var stderr = Data()
            let code = HostCLI.run(["calendar", "ls"], invoke: { _ in Data(value.utf8) }) {
                data, error in
                if error { stderr.append(data) } else { stdout.append(data) }
            }
            #expect(code == 1 && stdout.isEmpty && !stderr.isEmpty)
        }
    }
}
