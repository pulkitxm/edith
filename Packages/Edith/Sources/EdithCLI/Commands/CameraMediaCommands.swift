import ArgumentParser
import EdithKit
import Foundation

struct CameraVideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video", abstract: "Stream a local video through the meeting camera.",
        discussion: """
            Selects a local video file as the camera picture sent to your meeting.
            Playback loops unless --once is passed. The selected virtual camera stays
            the same when you switch between a physical camera, video and screen.

            Reads the video file and changes the saved camera source and playback.
            Requires the running Edith helper. Pause or resume with camera play.

            ed camera video /tmp/demo.mp4 --once
            """)

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
        commandName: "play", abstract: "Play or pause the selected video file.",
        discussion: """
            Controls playback of the video currently selected as your meeting source.
            Playing resumes its timeline, paused holds its current picture, and
            stopped returns the video timeline to its beginning. The video source
            stays selected so it can be played again without choosing another file.

            Changes saved playback state through the running Edith helper.
            Does not change the meeting application or its selected camera device.

            ed camera play paused --json
            """)

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
        commandName: "freeze", abstract: "Hold the last frame in the meeting.",
        discussion: """
            Freezes the most recent camera picture while retaining your selected
            source, framing, overlays and output device. Participants continue to
            receive that picture rather than newly captured frames. Resume the
            source when you want to return to live video.

            Changes the saved camera privacy state through the running Edith helper.
            Does not disable your meeting microphone or remove the camera source.

            ed camera freeze --json
            """)

    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.pause(.freeze, message: nil), json: json) }
    }
}

struct CameraMirrorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirror", abstract: "Flip the complete output, including overlays.",
        discussion: """
            Sets whether the complete camera output is flipped horizontally before
            it reaches participants. This includes text and logos. Meeting apps can
            separately mirror their local self view, so use the audience preview
            to check the picture participants actually receive.

            Changes the saved output orientation through the running Edith helper.
            Pass false to send readable text without an output flip.

            ed camera mirror false --json
            """)

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
        commandName: "record", abstract: "Record the composed camera output to MP4.",
        discussion: """
            Starts or finishes a local recording of the composed meeting camera.
            The recording includes the selected source, framing and overlays and
            can run even when no meeting app is consuming the virtual camera.
            Start requires a destination path; stop finishes the current file.

            Writes an MP4 at --path and changes recording state in the running helper.
            Does not upload the recording or change the selected meeting device.

            ed camera record start --path /tmp/demo.mp4 --json
            """)

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
        commandName: "screen", abstract: "List screens and windows, or use one as the camera.",
        discussion: """
            Lists available displays and windows with identifiers that can be
            selected as the meeting camera source. Pass a display:<id> or window:<id>
            from that list to switch the picture sent through your virtual camera.
            Capture requires the existing screen recording permission.

            Reads the screen source catalog for list. Selecting an identifier changes
            the saved camera source through the running Edith helper.

            ed camera screen list --json
            """)

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
