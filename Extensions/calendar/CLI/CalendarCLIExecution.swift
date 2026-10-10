import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum CalendarCLIEnvironment {
    static var readEvents: (CalendarEventQuery) async throws -> [CalendarEventPayload] = { _ in
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
        let previous = CalendarCLIEnvironment.readEvents
        CalendarCLIEnvironment.readEvents = read
        defer { CalendarCLIEnvironment.readEvents = previous }
        return try await ExtensionCLIExecution.run(
            CalendarCommand.self, arguments: request.arguments)
    }

    static func encoded(_ reply: ExtensionCLIReply) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(reply)
    }

}
