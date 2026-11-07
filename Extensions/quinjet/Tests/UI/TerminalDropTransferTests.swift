import Foundation
import Testing
@testable import QuinjetUI

struct TerminalDropTransferTests {
    @Test func sftpOptionsSurviveAControlPathWithSpaces() throws {
        let socket = "/Users/mock/Library/Application Support/Edith/machines/sockets/mock.sk"
        let arguments = try TerminalDropTransfer.sftpArguments(
            controlPath: socket, target: "mock@example.invalid")
        #expect(Array(arguments.prefix(2)) == ["-b", "-"])
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + arguments.dropFirst(2)
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let failure = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(failure)")
        #expect(printed.split(separator: "\n").contains("controlpath \(socket)"))
    }
}
