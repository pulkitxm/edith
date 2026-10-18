import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarCLIReplyEncodingTests {
    @Test func transportKeepsStreamsAndExitCodeWithoutEscapingSlashes() throws {
        let reply = try ExtensionCLIReply(
            stdout: "https://example.invalid/calendar/a/b\n",
            stderr: "synthetic /path/to/calendar failure\n", exitCode: 4)
        let data = try CalendarCLIExecution.encoded(reply)
        #expect(!String(decoding: data, as: UTF8.self).contains("\\/"))
        #expect(try JSONDecoder().decode(ExtensionCLIReply.self, from: data) == reply)
    }
}
