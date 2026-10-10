import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum CalendarCLIEnvironment {
    @TaskLocal static var readEvents:
        @MainActor (CalendarEventQuery) async throws ->
            [CalendarEventPayload] = { _ in
                throw CLIFailure.unavailable(
                    "the Calendar extension is off", hint: "run `ed extensions enable calendar`")
            }
    static var openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    static var openCalendar: @MainActor (URL) -> Void = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

@MainActor enum CalendarCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest,
        read: @escaping (CalendarEventQuery) async throws -> [CalendarEventPayload]
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        return try await CalendarCLIEnvironment.$readEvents.withValue(read) {
            try await ExtensionCLIExecution.run(CalendarCommand.self, request: request)
        }
    }

    static func encoded(_ reply: ExtensionCLIReply) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(reply)
    }

}
