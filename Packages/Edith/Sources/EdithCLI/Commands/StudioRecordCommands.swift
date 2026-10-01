import ArgumentParser
import EdithKit
import Foundation

struct StudioRecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record the screen into a Studio video.",
        discussion: """
            Reads capture sources and writes a movie when you start and stop. This is the
            Record a video sheet: a display or window, system audio, the microphone and the
            cursor. Example: `ed studio record sources --json`.
            """,
        subcommands: [
            StudioRecordSourcesCommand.self, StudioRecordStartCommand.self,
            StudioRecordStopCommand.self, StudioRecordStatusCommand.self,
        ],
        defaultSubcommand: StudioRecordStatusCommand.self)
}

enum StudioRecordCLI {
    static let name = "screen recording"

    static func request(
        _ request: StudioRecordRequest, source: String = "", systemAudio: Bool = true,
        microphone: Bool = false, showCursor: Bool = true
    ) async throws -> StudioRecordSnapshot {
        try AppBridge.requireMainApp(name)
        let timeout: TimeInterval = request == .stop ? 30 : 12
        let runtime = StudioRecordRuntimeRequest(
            request: request, source: source, systemAudio: systemAudio, microphone: microphone,
            showCursor: showCursor, deadline: Date().addingTimeInterval(timeout))
        let requestID = runtime.requestID
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.studioRecordResult, timeout: timeout,
                matching: { $0[StudioRecordIPC.requestIDKey] as? String == requestID },
                trigger: { AppBridge.post(IPC.Name.requestStudioRecord, userInfo: runtime.payload) }
            )
        else { throw AppBridge.silence(name) }
        guard reply[StudioRecordIPC.okKey] as? Bool == true else {
            throw CLIFailure(
                reply[StudioRecordIPC.errorKey] as? String ?? "The recording request failed")
        }
        guard
            let snapshot = StudioRecordSnapshot.decode(
                reply[StudioRecordIPC.snapshotKey] as? String)
        else { throw CLIFailure("Edith sent an unreadable recording status") }
        return snapshot
    }

    static func emit(_ snapshot: StudioRecordSnapshot, json: Bool) {
        if json {
            CLIOut.json(
                .object([
                    "changed": .bool(snapshot.changed),
                    "cursor": .bool(snapshot.showCursor),
                    "microphone": .bool(snapshot.microphone),
                    "output": snapshot.output.map(JSONValue.string) ?? .null,
                    "recording": .bool(snapshot.recording),
                    "source": .string(snapshot.source),
                    "sources": .array(
                        snapshot.sources.map {
                            .object([
                                "id": .string($0.id), "kind": .string($0.kind),
                                "title": .string($0.title),
                            ])
                        }),
                    "systemAudio": .bool(snapshot.systemAudio),
                ]))
            return
        }
        if snapshot.recording {
            CLIOut.out("Recording \(snapshot.source)")
        } else if let output = snapshot.output {
            CLIOut.out(output)
        } else if snapshot.sources.isEmpty {
            CLIOut.out("No recording is in progress.")
        } else {
            for source in snapshot.sources { CLIOut.out("\(source.id)\t\(source.title)") }
        }
    }
}

struct StudioRecordSourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "List displays and windows that can be recorded.",
        discussion: """
            Reads the same picker as the recording sheet. Example: `ed studio record sources --json`.
            """)

    @Flag(name: .long, help: "Emit the sources as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            StudioRecordCLI.emit(try await StudioRecordCLI.request(.sources), json: json)
        }
    }
}

struct StudioRecordStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start recording a display or window.",
        discussion: """
            Writes a new capture, the same one the recording sheet starts. System audio and
            the cursor are included unless you opt out.
            Example: `ed studio record start --display 1 --json`.
            """)

    @Option(name: .long, help: "A display id from `ed studio record sources`.")
    var display: String?

    @Option(name: .long, help: "A window id from `ed studio record sources`.")
    var window: String?

    @Flag(name: .customLong("microphone"), help: "Also record the microphone.")
    var microphone = false

    @Flag(name: .customLong("no-system-audio"), help: "Leave system audio out.")
    var noSystemAudio = false

    @Flag(name: .customLong("no-cursor"), help: "Leave the pointer out.")
    var noCursor = false

    @Flag(name: .long, help: "Emit the recording status as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            if display != nil && window != nil {
                throw CLIFailure.usage("pass either --display or --window")
            }
            let source = display.map { "display:\($0)" } ?? window.map { "window:\($0)" } ?? ""
            StudioRecordCLI.emit(
                try await StudioRecordCLI.request(
                    .start, source: source, systemAudio: !noSystemAudio, microphone: microphone,
                    showCursor: !noCursor), json: json)
        }
    }
}

struct StudioRecordStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the screen recording and print its file.",
        discussion: """
            Writes the finished movie and prints its path.
            Example: `ed studio record stop --json`.
            """)

    @Flag(name: .long, help: "Emit the finished recording as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            StudioRecordCLI.emit(try await StudioRecordCLI.request(.stop), json: json)
        }
    }
}

struct StudioRecordStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Read whether a screen recording is in progress.",
        discussion: """
            Reads the capture the recording sheet or `ed studio record start` began.
            Example: `ed studio record status --json`.
            """)

    @Flag(name: .long, help: "Emit the recording status as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            StudioRecordCLI.emit(try await StudioRecordCLI.request(.status), json: json)
        }
    }
}
