import ArgumentParser
import EdithKit

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Screen recognition, screenshots, and recent captures.",
        subcommands: [
            CaptureReadCommand.self, CaptureAreaCommand.self, CaptureWindowCommand.self,
            CaptureScreenCommand.self, CaptureLibraryCommand.self,
        ],
        defaultSubcommand: CaptureReadCommand.self)
}

enum CaptureCommandBridge {
    static func request(_ operation: CaptureToolOperation, json: Bool) async throws {
        try await execute {
            guard
                CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.Capture.enabled)
                    as? Bool == true
            else {
                throw CLIFailure.unavailable(
                    "the Capture Tools extension is off",
                    hint: "run `ed extensions enable captureTools`, then retry")
            }
            try AppBridge.requireHelper("capturing the screen")
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
