import ArgumentParser
import EdithKit
import Foundation

struct CameraVideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video", abstract: "Use a video file as the meeting camera.")

    @Argument(help: "Path to a video file.") var path: String
    @Flag(help: "Play once instead of looping.") var once = false
    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try await CameraCLI.perform(
                .media(VirtualCameraMedia(kind: .video, path: url.path, loop: !once)), json: json)
        }
    }
}

struct CameraPlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play", abstract: "Play or pause the selected video file.")

    @Argument(help: "playing, paused or stopped.") var action = "playing"
    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute {
            guard let mode = VirtualCameraPlayback(rawValue: action) else {
                throw CLIFailure("Use playing, paused or stopped.")
            }
            try await CameraCLI.perform(.playback(mode), json: json)
        }
    }
}

struct CameraFreezeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "freeze", abstract: "Hold the last frame in the meeting.")

    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.pause(.freeze, message: nil), json: json) }
    }
}

struct CameraMirrorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirror", abstract: "Flip the complete output, including overlays.")

    @Argument(help: "true or false. This changes what participants receive.") var enabled: String
    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute {
            try await CameraCLI.perform(
                .mirrorOutput(try ConfigValueParser.boolean(enabled)), json: json)
        }
    }
}

struct CameraRecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record", abstract: "Record the composed camera output to MP4.")

    @Argument(help: "start or stop.") var action: String
    @Option(help: "Destination MP4 path for start.") var path: String?
    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute {
            switch action {
            case "start":
                guard let path else { throw CLIFailure("Pass --path for the recording.") }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                try await CameraCLI.perform(.recordStart(url.path), json: json)
            case "stop": try await CameraCLI.perform(.recordStop, json: json)
            default: throw CLIFailure("Use start or stop.")
            }
        }
    }
}

struct CameraScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen", abstract: "List screens and windows, or use one as the camera.")

    @Argument(help: "A display:<id> or window:<id>, or list.") var source = "list"
    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute {
            let snapshot = try await CameraCLI.request(.screenSources)
            let sources = snapshot.screenSources ?? []
            if source == "list" {
                if json {
                    CLIOut.json(
                        .array(
                            sources.map {
                                .object([
                                    "id": .string($0.id), "name": .string($0.name),
                                    "kind": .string($0.kind),
                                ])
                            }))
                } else {
                    sources.forEach { CLIOut.out("\($0.id): \($0.name)") }
                }
                return
            }
            guard sources.contains(where: { $0.id == source }) else {
                throw CLIFailure("Choose an id from ed camera screen list.")
            }
            try await CameraCLI.perform(
                .media(VirtualCameraMedia(kind: .screen, screenID: source)), json: json)
        }
    }
}
