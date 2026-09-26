import ArgumentParser
import EdithKit
import Foundation

struct CameraCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camera",
        abstract: "Frame, style and control Edith's virtual camera.",
        subcommands: [
            CameraStatusCommand.self, CameraOnCommand.self, CameraOffCommand.self,
            CameraSourcesCommand.self, CameraSourceCommand.self, CameraZoomCommand.self,
            CameraFrameCommand.self, CameraResetCommand.self, CameraLookCommand.self,
            CameraBackgroundCommand.self, CameraPauseCommand.self, CameraResumeCommand.self,
            CameraSceneCommand.self,
        ],
        defaultSubcommand: CameraStatusCommand.self)
}

enum CameraCLI {
    static let name = "Virtual Camera"

    static func request(_ request: VirtualCameraRequest) async throws -> VirtualCameraSnapshot {
        try AppBridge.requireHelper(name)
        let timeout: TimeInterval = request == .status ? 3 : 10
        let runtime = VirtualCameraRuntimeRequest(
            request: request, deadline: Date().addingTimeInterval(timeout))
        guard let payload = runtime.payload else {
            throw CLIFailure("The camera request could not be encoded")
        }
        let requestID = runtime.requestID
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.virtualCameraActionResult, timeout: timeout,
                matching: { $0[VirtualCameraIPC.requestIDKey] as? String == requestID },
                trigger: {
                    AppBridge.post(IPC.Name.requestVirtualCameraAction, userInfo: payload)
                })
        else {
            throw AppBridge.silence(
                name, extensionKey: AppStorageKeys.VirtualCamera.enabled, permission: "camera")
        }
        guard reply[VirtualCameraIPC.okKey] as? Bool == true else {
            throw CLIFailure(
                reply[VirtualCameraIPC.errorKey] as? String ?? "The camera request failed")
        }
        guard
            let snapshot = VirtualCameraSnapshot.decode(
                reply[VirtualCameraIPC.snapshotKey] as? String)
        else { throw CLIFailure("Edith sent an unreadable camera status") }
        return snapshot
    }

    static func status() async throws -> VirtualCameraSnapshot {
        guard AppBridge.helperIsRunning else {
            return VirtualCameraSnapshot.stored(CLIEnvironment.sharedDefaults)
        }
        return try await request(.status)
    }

    static func emit(_ snapshot: VirtualCameraSnapshot, json: Bool) {
        if json {
            CLIOut.json(snapshot.jsonValue)
        } else if let message = snapshot.message {
            CLIOut.out(message)
        } else {
            snapshot.summaryLines.forEach { CLIOut.out($0) }
        }
    }

    static func perform(_ request: VirtualCameraRequest, json: Bool) async throws {
        emit(try await self.request(request), json: json)
    }

    static func setEnabled(_ enabled: Bool, json: Bool) async throws {
        guard let entry = VirtualCameraOperationExecution.extensionEntry else {
            throw CLIFailure("The Virtual Camera extension is not registered")
        }
        let result = ExtensionLookup.mutationCenter().setEnabled(enabled, for: entry)
        if json {
            CLIOut.json(
                .object([
                    "enabled": .bool(enabled),
                    "missingPermissions": .array(
                        result.missingRequiredPermissions.map { .string($0.rawValue) }),
                ]))
            return
        }
        CLIOut.out("virtual camera \(enabled ? "on" : "off")")
        for permission in result.missingRequiredPermissions where enabled {
            CLIOut.note(
                "note: Virtual Camera needs \(permission.displayName); "
                    + "run `ed permissions request \(permission.rawValue)`")
        }
    }

    static func number(_ raw: String, _ name: String) throws -> Double {
        guard let value = Double(raw.replacingOccurrences(of: "x", with: "")), value.isFinite
        else { throw CLIFailure("\(raw) is not a number for \(name)") }
        return value
    }

    static func autoFrame(_ raw: String) throws -> VirtualCameraAutoFrame {
        guard let value = VirtualCameraAutoFrame(rawValue: raw.lowercased()) else {
            throw CLIFailure(
                "\(raw) is not an auto framing mode", hint: "use off, close, medium or wide")
        }
        return value
    }

    static func look(_ raw: String) throws -> VirtualCameraLookPreset {
        guard let value = VirtualCameraLookPreset(rawValue: raw.lowercased()) else {
            throw CLIFailure(
                "\(raw) is not a look",
                hint: VirtualCameraLookPreset.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    static func background(_ raw: String) throws -> VirtualCameraBackgroundMode {
        let normalized = raw.lowercased() == "original" ? "none" : raw.lowercased()
        guard let value = VirtualCameraBackgroundMode(rawValue: normalized) else {
            throw CLIFailure("\(raw) is not a background", hint: "use none, blur, color or image")
        }
        return value
    }

    static func pause(_ raw: String) throws -> VirtualCameraPrivacy {
        guard let value = VirtualCameraPrivacy(rawValue: raw.lowercased()), value != .live else {
            throw CLIFailure("\(raw) is not a pause style", hint: "use card, blank or freeze")
        }
        return value
    }
}

struct CameraStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: VirtualCameraOperation.status.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            var snapshot = try await CameraCLI.status()
            snapshot.message = nil
            CameraCLI.emit(snapshot, json: json)
        }
    }
}

struct CameraOnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on", abstract: VirtualCameraOperation.on.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.setEnabled(true, json: json) }
    }
}

struct CameraOffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off", abstract: VirtualCameraOperation.off.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.setEnabled(false, json: json) }
    }
}

struct CameraSourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources", abstract: VirtualCameraOperation.sources.descriptor.summary,
        aliases: ["cameras"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let snapshot = try await CameraCLI.request(.status)
            if json {
                CLIOut.json(.array(snapshot.sources.map(\.jsonValue)))
                return
            }
            guard !snapshot.sources.isEmpty else {
                CLIOut.out("no cameras")
                return
            }
            for (index, source) in snapshot.sources.enumerated() {
                let marker = source.id == snapshot.source?.id ? "*" : " "
                CLIOut.out("\(marker) \(index + 1). \(source.name) [\(source.kind.rawValue)]")
            }
        }
    }
}

struct CameraSourceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "source", abstract: VirtualCameraOperation.source.descriptor.summary)

    @Argument(help: "A camera name, its number from `ed camera sources`, or its id.")
    var camera: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.selectSource(camera), json: json) }
    }
}

struct CameraZoomCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zoom", abstract: VirtualCameraOperation.zoom.descriptor.summary)

    @Argument(help: "A zoom level from 1 to 8, such as 1.5 or 2x.")
    var level: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await CameraCLI.perform(.zoom(try CameraCLI.number(level, "zoom")), json: json)
        }
    }
}

struct CameraFrameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frame", abstract: VirtualCameraOperation.frame.descriptor.summary)

    @Option(help: "Zoom level from 1 to 8.")
    var zoom: Double?

    @Option(help: "Horizontal center from 0 (left) to 1 (right).")
    var x: Double?

    @Option(help: "Vertical center from 0 (top) to 1 (bottom).")
    var y: Double?

    @Option(help: "Tilt in degrees from -45 to 45.")
    var tilt: Double?

    @Option(help: "Quarter turns clockwise, from 0 to 3.")
    var turns: Int?

    @Option(help: "Flip the picture horizontally: true or false.")
    var flip: String?

    @Option(name: .customLong("flip-vertical"), help: "Flip the picture vertically: true or false.")
    var flipVertical: String?

    @Option(help: "Auto framing: off, close, medium or wide.")
    var auto: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let change = VirtualCameraFrameChange(
                zoom: zoom, centerX: x, centerY: y, tilt: tilt, quarterTurns: turns,
                flipHorizontal: try flip.map(ConfigValueParser.boolean),
                flipVertical: try flipVertical.map(ConfigValueParser.boolean),
                autoFrame: try auto.map(CameraCLI.autoFrame))
            guard !change.isEmpty else {
                throw CLIFailure(
                    VirtualCameraRequestError.emptyFrameChange.errorDescription
                        ?? "Nothing to change")
            }
            try await CameraCLI.perform(.frame(change), json: json)
        }
    }
}

struct CameraResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset", abstract: VirtualCameraOperation.reset.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.reset, json: json) }
    }
}

struct CameraLookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "look", abstract: VirtualCameraOperation.look.descriptor.summary)

    @Argument(help: "natural, bright, studio, warm, cool, vivid, muted, film, mono or noir.")
    var preset: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await CameraCLI.perform(.look(try CameraCLI.look(preset)), json: json)
        }
    }
}

struct CameraBackgroundCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "background", abstract: VirtualCameraOperation.background.descriptor.summary)

    @Argument(help: "none, blur, color or image.")
    var mode: String

    @Option(help: "Backdrop color as a hex value, such as #1E293B.")
    var color: String?

    @Option(help: "Blur strength from 0 to 1.")
    var blur: Double?

    @Option(help: "Path to a backdrop image.")
    var image: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            var parsedColor: VirtualCameraColor?
            if let color {
                guard let value = VirtualCameraColor(hex: color) else {
                    throw CLIFailure(
                        "\(color) is not a hex color", hint: "use a value like #1E293B")
                }
                parsedColor = value
            }
            let path = image.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).path
            }
            let change = VirtualCameraBackgroundChange(
                mode: try CameraCLI.background(mode), color: parsedColor, blur: blur,
                imagePath: path)
            try await CameraCLI.perform(.background(change), json: json)
        }
    }
}

struct CameraPauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause", abstract: VirtualCameraOperation.pause.descriptor.summary)

    @Option(help: "card, blank or freeze.")
    var style = "card"

    @Option(help: "The message on the card.")
    var message: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await CameraCLI.perform(
                .pause(try CameraCLI.pause(style), message: message), json: json)
        }
    }
}

struct CameraResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume", abstract: VirtualCameraOperation.resume.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.resume, json: json) }
    }
}

struct CameraSceneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scene",
        abstract: "List, apply and save camera scenes.",
        subcommands: [
            CameraSceneListCommand.self, CameraSceneApplyCommand.self,
            CameraSceneSaveCommand.self, CameraSceneNextCommand.self,
            CameraScenePreviousCommand.self,
        ],
        defaultSubcommand: CameraSceneListCommand.self)
}

struct CameraSceneListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: VirtualCameraOperation.sceneList.descriptor.summary,
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let snapshot = try await CameraCLI.status()
            if json {
                CLIOut.json(snapshot.scenesJSON)
                return
            }
            guard !snapshot.state.scenes.isEmpty else {
                CLIOut.out("no scenes")
                return
            }
            for (index, scene) in snapshot.state.scenes.enumerated() {
                let marker = scene.id == snapshot.state.activeSceneID ? "*" : " "
                CLIOut.out("\(marker) \(index + 1). \(scene.name)")
            }
        }
    }
}

struct CameraSceneApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply", abstract: VirtualCameraOperation.sceneApply.descriptor.summary)

    @Argument(help: "A scene name, its number from `ed camera scene list`, or its id.")
    var scene: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.applyScene(scene), json: json) }
    }
}

struct CameraSceneSaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save", abstract: VirtualCameraOperation.sceneSave.descriptor.summary)

    @Argument(help: "The scene name.")
    var name: String

    @Flag(help: "Overwrite a scene with the same name.")
    var replace = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await CameraCLI.perform(.saveScene(name, replace: replace), json: json)
        }
    }
}

struct CameraSceneNextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next", abstract: VirtualCameraOperation.sceneNext.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.stepScene(1), json: json) }
    }
}

struct CameraScenePreviousCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previous",
        abstract: VirtualCameraOperation.scenePrevious.descriptor.summary, aliases: ["prev"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute { try await CameraCLI.perform(.stepScene(-1), json: json) }
    }
}
