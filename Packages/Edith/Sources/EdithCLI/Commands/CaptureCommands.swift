import ArgumentParser
import EdithKit

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Offline screen recognition and quick screenshots.",
        subcommands: [CaptureReadCommand.self, CaptureScreenshotCommand.self])
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
            CLIOut.out(operation == .read ? "screen read requested" : "screenshot requested")
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

struct CaptureScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot", abstract: "Select screen content for a quick preview.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await CaptureCommandBridge.request(.screenshot, json: json)
    }
}
