import ArgumentParser
import EdithKit
import Foundation

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Screen recognition, screenshots, and recent captures.",
        subcommands: [
            CaptureReadCommand.self, CaptureAreaCommand.self, CaptureWindowCommand.self,
            CaptureScreenCommand.self, CaptureLibraryCommand.self, CaptureRecordCommand.self,
        ],
        defaultSubcommand: CaptureReadCommand.self)
}

struct CaptureRecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record", abstract: "Record and edit an area, window, or display.",
        subcommands: [
            CaptureRecordAreaCommand.self, CaptureRecordWindowCommand.self,
            CaptureRecordDisplayCommand.self, CaptureRecordPauseCommand.self,
            CaptureRecordResumeCommand.self, CaptureRecordStopCommand.self,
            CaptureRecordCancelCommand.self, CaptureRecordStatusCommand.self,
            CaptureRecordLibraryCommand.self, CaptureRecordExportCommand.self,
        ], defaultSubcommand: CaptureRecordAreaCommand.self)
}

private enum CaptureRecordBridge {
    static func request(_ operation: ScreenRecordingOperation, json: Bool) async throws {
        try await execute {
            guard
                ExtensionRegistry.entry("captureTools")?.isEnabled(
                    in: CLIEnvironment.sharedDefaults) == true
            else {
                throw CLIFailure.unavailable(
                    "the Capture Tools extension is off",
                    hint: "run `ed extensions enable captureTools`, then retry")
            }
            if operation == .status {
                outputStatus(
                    ScreenRecordingStatusStore.load(defaults: CLIEnvironment.sharedDefaults),
                    json: json)
                return
            }
            try AppBridge.requireHelper("controlling Screen Recorder")
            let descriptor = ScreenRecordingOperation.request(operation) { AppBridge.post($0) }
            if json {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "requested": .bool(true),
                        "interactive": .bool(descriptor.effect == .interactive),
                    ]))
            } else {
                CLIOut.out("\(operation.rawValue) requested")
            }
        }
    }

    private static func outputStatus(_ status: ScreenRecordingStatus, json: Bool) {
        if json {
            var object: [String: JSONValue] = [
                "state": .string(status.state.rawValue),
                "elapsedSeconds": .double(status.elapsedSeconds),
            ]
            if let source = status.source { object["source"] = .string(source.rawValue) }
            if let takeID = status.takeID { object["takeId"] = .string(takeID.uuidString) }
            if let message = status.message { object["message"] = .string(message) }
            CLIOut.json(.object(object))
        } else {
            let source = status.source.map { " \($0.rawValue)" } ?? ""
            CLIOut.out(
                "\(status.state.rawValue)\(source) \(String(format: "%.1fs", status.elapsedSeconds))"
            )
        }
    }
}

private protocol CaptureRecordRequest: AsyncParsableCommand {
    static var operation: ScreenRecordingOperation { get }
    var json: Bool { get }
}

extension CaptureRecordRequest {
    func run() async throws {
        try await CaptureRecordBridge.request(Self.operation, json: json)
    }
}

struct CaptureRecordAreaCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "area", abstract: "Select and record an area.")
    static let operation = ScreenRecordingOperation.area
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordWindowCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "window", abstract: "Choose and record a window.")
    static let operation = ScreenRecordingOperation.window
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordDisplayCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "display", abstract: "Choose and record a display.")
    static let operation = ScreenRecordingOperation.display
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordPauseCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "pause", abstract: "Pause the active recording.")
    static let operation = ScreenRecordingOperation.pause
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordResumeCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "resume", abstract: "Resume the active recording.")
    static let operation = ScreenRecordingOperation.resume
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordStopCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop and edit the active recording.")
    static let operation = ScreenRecordingOperation.stop
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordCancelCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "cancel", abstract: "Discard the active recording.")
    static let operation = ScreenRecordingOperation.cancel
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordStatusCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Read the current recording state.")
    static let operation = ScreenRecordingOperation.status
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

struct CaptureRecordLibraryCommand: CaptureRecordRequest {
    static let configuration = CommandConfiguration(
        commandName: "library", abstract: "Open recent and recovered recordings.")
    static let operation = ScreenRecordingOperation.library
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

enum CaptureCommandBridge {
    static func request(_ operation: CaptureToolOperation, json: Bool) async throws {
        try await execute {
            guard
                ExtensionRegistry.entry("captureTools")?.isEnabled(
                    in: CLIEnvironment.sharedDefaults) == true
            else {
                throw CLIFailure.unavailable(
                    "the Capture Tools extension is off",
                    hint: "run `ed extensions enable captureTools`, then retry")
            }
            try AppBridge.requireHelper(
                operation == .library ? "opening recent captures" : "capturing the screen")
            let descriptor = CaptureToolOperationExecution.request(operation) {
                AppBridge.post($0)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "requested": .bool(true),
                    ]))
                return
            }
            CLIOut.out("\(operation.rawValue) requested")
        }
    }
}

struct CaptureReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read", abstract: "Select screen content and copy recognized text or codes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await CaptureCommandBridge.request(.read, json: json)
    }
}

struct CaptureAreaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "area", abstract: "Capture a selected area.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await CaptureCommandBridge.request(.area, json: json)
    }
}

struct CaptureWindowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window", abstract: "Capture a selected window.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await CaptureCommandBridge.request(.window, json: json)
    }
}

struct CaptureScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen", abstract: "Capture the full main display.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await CaptureCommandBridge.request(.screen, json: json)
    }
}

struct CaptureLibraryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library", abstract: "Open recent captures.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await CaptureCommandBridge.request(.library, json: json)
    }
}

struct CaptureRecordExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export a saved recording through the background agent.")
    @Argument(help: "The recording identifier from its library folder.") var id: String
    @Option(name: .customLong("to"), help: "A new MP4 or GIF output file.") var destination: String
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            guard let identifier = UUID(uuidString: id),
                let take = ScreenRecordingLibrary.load().first(where: { $0.id == identifier })
            else { throw CLIFailure.notFound("no recording with that identifier") }
            let output = URL(fileURLWithPath: NSString(string: destination).expandingTildeInPath)
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw CLIFailure.usage("choose a new output file to preserve the existing file")
            }
            guard let format = ScreenRecordingFormat(rawValue: output.pathExtension.lowercased())
            else {
                throw CLIFailure.usage("the output filename must end in .mp4 or .gif")
            }
            var document =
                (try? Data(contentsOf: ScreenRecordingLibrary.editURL(for: take.id)))
                .flatMap { try? JSONDecoder().decode(ScreenRecordingEditDocument.self, from: $0) }
                ?? ScreenRecordingEditDocument(trimEnd: take.duration)
            document.preset.format = format
            try await AgentRecordingExportClient.export(take: take, document: document, to: output)
            if json {
                CLIOut.json(
                    .object([
                        "operation": .string("capture.record.export"),
                        "output": .string(output.path),
                    ]))
            } else {
                CLIOut.out("exported recording to \(output.path)")
            }
        }
    }
}
