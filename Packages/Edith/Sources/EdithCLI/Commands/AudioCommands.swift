import ArgumentParser
import EdithKit
import Foundation

struct AudioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Set the volume of apps that are playing sound.",
        discussion: """
            Reads the playing apps and writes a volume when you set, mute, or unmute one.
            This is the per-app mixer in the notch. The on/off switch stays `ed config`.
            Example: `ed audio ls --json`.
            """,
        subcommands: [
            AudioListCommand.self, AudioVolumeCommand.self, AudioMuteCommand.self,
            AudioUnmuteCommand.self,
        ],
        defaultSubcommand: AudioListCommand.self)
}

enum AudioCLI {
    static let name = "the audio mixer"

    static func request(_ request: AudioMixerRequest, app: String = "", volume: Double = 1)
        async throws -> AudioMixerListSnapshot
    {
        try AppBridge.requireHelper(name)
        let timeout: TimeInterval = 8
        let runtime = AudioMixerRuntimeRequest(
            request: request, app: app, volume: volume,
            deadline: Date().addingTimeInterval(timeout))
        let requestID = runtime.requestID
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.audioMixerActionResult, timeout: timeout,
                matching: { $0[AudioMixerIPC.requestIDKey] as? String == requestID },
                trigger: {
                    AppBridge.post(IPC.Name.requestAudioMixerAction, userInfo: runtime.payload)
                }
            )
        else { throw AppBridge.silence(name) }
        guard reply[AudioMixerIPC.okKey] as? Bool == true else {
            throw CLIFailure(
                reply[AudioMixerIPC.errorKey] as? String ?? "The audio mixer request failed")
        }
        guard
            let snapshot = AudioMixerListSnapshot.decode(
                reply[AudioMixerIPC.snapshotKey] as? String)
        else { throw CLIFailure("Edith sent an unreadable audio mixer list") }
        return snapshot
    }

    static func emit(_ snapshot: AudioMixerListSnapshot, json: Bool) {
        if json {
            CLIOut.json(
                .object([
                    "apps": .array(snapshot.apps.map(jsonApp)),
                    "changed": .bool(snapshot.changed),
                ]))
            return
        }
        if snapshot.apps.isEmpty {
            CLIOut.out("No app is playing audio.")
            return
        }
        for app in snapshot.apps {
            let state = app.muted ? "muted" : "\(app.percent)"
            CLIOut.out("\(app.name)\t\(app.bundleID)\t\(state)")
        }
    }

    static func percent(_ value: Double) throws -> Double {
        guard (0...100).contains(value) else {
            throw CLIFailure.usage(
                "volume must be from 0 to 100", hint: "0 mutes the app and 100 restores it")
        }
        return value / 100
    }

    private static func jsonApp(_ app: AudioMixerAppRecord) -> JSONValue {
        .object([
            "bundleID": .string(app.bundleID),
            "muted": .bool(app.muted),
            "name": .string(app.name),
            "percent": .int(app.percent),
            "pid": .int(Int(app.pid)),
        ])
    }
}

struct AudioListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List apps that are playing audio.",
        discussion: """
            Reads the same list as the notch mixer. Example: `ed audio ls --json`.
            """)

    @Flag(name: .long, help: "Emit the playing apps as JSON.")
    var json = false

    func run() async throws {
        try await execute { AudioCLI.emit(try await AudioCLI.request(.list), json: json) }
    }
}

struct AudioVolumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Set one playing app's volume.",
        discussion: """
            Writes that app's slider in the notch mixer. 0 mutes it and 100 restores full
            volume, which removes the audio tap. Example: `ed audio volume Music 40 --json`.
            """)

    @Argument(help: "The app name, bundle id, or process id.")
    var app: String

    @Argument(help: "Volume from 0 to 100.")
    var level: Double

    @Flag(name: .long, help: "Emit the mixer list as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            let unit = try AudioCLI.percent(level)
            AudioCLI.emit(try await AudioCLI.request(.volume, app: app, volume: unit), json: json)
        }
    }
}

struct AudioMuteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute",
        abstract: "Mute one playing app.",
        discussion: """
            Writes that app's mixer slider to 0 in the notch mixer.
            Example: `ed audio mute Music --json`.
            """)

    @Argument(help: "The app name, bundle id, or process id.")
    var app: String

    @Flag(name: .long, help: "Emit the mixer list as JSON.")
    var json = false

    func run() async throws {
        try await execute { AudioCLI.emit(try await AudioCLI.request(.mute, app: app), json: json) }
    }
}

struct AudioUnmuteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmute",
        abstract: "Restore one playing app to full volume.",
        discussion: """
            Writes that app's mixer slider to 100 and removes its audio tap.
            Example: `ed audio unmute Music --json`.
            """)

    @Argument(help: "The app name, bundle id, or process id.")
    var app: String

    @Flag(name: .long, help: "Emit the mixer list as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            AudioCLI.emit(try await AudioCLI.request(.unmute, app: app), json: json)
        }
    }
}
