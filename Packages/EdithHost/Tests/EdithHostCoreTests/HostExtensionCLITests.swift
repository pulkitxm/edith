import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostExtensionCLITests {
    @Test func originalArgumentsAreForwardedOnlyToTheOwningExtension() throws {
        for arguments in [[], ["ls", "--json"], ["route", "synthetic-id"], ["--help"]] {
            guard case .terminal(let request) = try HostCLICommand.parse(["calendar"] + arguments)
            else { Issue.record("The original Calendar command was not routed"); return }
            #expect(request.action == .terminal)
            #expect(request.id == "calendar" && request.operation == "calendar.cli")
            let payload = try JSONDecoder().decode(ExtensionCLIRequest.self, from: request.payload)
            #expect(payload.arguments == arguments)
            #expect(try HostCLIRequest.decoded(request.encoded()) == request)
        }
    }

    @Test func decodedTerminalRequestsCannotChooseAnotherOperationOrBypassLimits() throws {
        let payload = try JSONEncoder().encode(ExtensionCLIRequest(arguments: []))
        for (id, operation) in [
            ("calendar", "calendar.erase"), ("database", "calendar.cli"),
            ("calendar", "extension.native.authorize"),
        ] {
            #expect(throws: HostCLIError.self) {
                try HostCLIRequest(
                    action: .terminal, id: id, operation: operation, payload: payload)
            }
        }
        #expect(throws: HostCLIError.self) {
            try HostCLICommand.parse(["calendar", String(repeating: "x", count: 4_097)])
        }
        #expect(throws: HostCLIError.self) {
            try HostCLICommand.parse(["extensions", "terminal", "calendar"])
        }
        let invalid = try JSONSerialization.data(withJSONObject: ["arguments": ["bad\0"]])
        #expect(throws: HostCLIError.self) {
            try HostCLIRequest(
                action: .terminal, id: "calendar", operation: "calendar.cli", payload: invalid)
        }
    }

    @Test func terminalOutputAndAllOriginalExitCodesArePreservedExactly() throws {
        for code: Int32 in [0, 1, 2, 3, 4, 130] {
            var stdout = Data()
            var stderr = Data()
            let reply = try ExtensionCLIReply(
                stdout: "synthetic output without newline", stderr: "synthetic diagnostic\n",
                exitCode: code)
            let result = HostCLI.run(
                ["calendar", "ls"],
                invoke: { request in
                    #expect(request.action == .terminal)
                    return try JSONEncoder().encode(reply)
                }
            ) { data, error in
                if error { stderr.append(data) } else { stdout.append(data) }
            }
            #expect(result == code)
            #expect(stdout == Data(reply.stdout.utf8) && stderr == Data(reply.stderr.utf8))
        }
    }

    @Test func unavailableAppAndInvalidResponsesNeverBecomeSuccessfulTerminalOutput() throws {
        var stdout = Data()
        var stderr = Data()
        let unavailable = HostCLI.run(
            ["calendar", "ls"],
            invoke: { _ in
                throw HostCLIError.unavailable
            }
        ) { data, error in
            if error { stderr.append(data) } else { stdout.append(data) }
        }
        #expect(unavailable == 4 && stdout.isEmpty)
        #expect(String(decoding: stderr, as: UTF8.self).hasPrefix("error: Edith is not running"))
        stdout = Data(); stderr = Data()
        let rejected = HostCLI.run(
            ["calendar", "ls"],
            invoke: { _ in
                Data("{\"stdout\":\"must not print\",\"stderr\":\"\",\"exitCode\":256}".utf8)
            }
        ) { data, error in
            if error { stderr.append(data) } else { stdout.append(data) }
        }
        #expect(rejected == 1 && stdout.isEmpty && !stderr.isEmpty)
    }
}
