import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct CameraExtensionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extension",
        abstract: "Install or remove the Edith Camera system extension.",
        discussion: """
            Reads the extension status. Install and remove write that change when you pass
            --yes. These are the Install, Remove and Check again buttons in the camera
            inspector. Example: `ed camera extension status --json`.
            """,
        subcommands: [
            CameraExtensionStatusCommand.self, CameraExtensionInstallCommand.self,
            CameraExtensionRemoveCommand.self,
        ],
        defaultSubcommand: CameraExtensionStatusCommand.self)
}

@MainActor enum CameraExtensionCLI {
    static let name = "Edith Camera"

    static func request(_ request: CameraExtensionRequest) async throws -> CameraExtensionSnapshot {
        guard let engine = CameraCLIEnvironment.currentEngine else {
            throw ExtensionPeerError.unavailable
        }
        guard request == .status else {
            throw CLIFailure(
                .unavailable, "Camera video uses OBS Virtual Camera. Keep OBS Studio closed.")
        }
        let snapshot = engine.snapshot()
        return CameraExtensionSnapshot(
            phase: snapshot.obsAvailable ? "ready" : "unavailable", title: "OBS Virtual Camera",
            detail: snapshot.obsAvailable
                ? "OBS Virtual Camera is available. Keep OBS Studio closed."
                : "Install OBS Studio to provide OBS Virtual Camera, then keep OBS Studio closed.",
            changed: false)
    }

    static func emit(_ snapshot: CameraExtensionSnapshot, json: Bool) {
        if json {
            CLIOut.json(
                .object([
                    "changed": .bool(snapshot.changed),
                    "detail": .string(snapshot.detail),
                    "phase": .string(snapshot.phase),
                    "title": .string(snapshot.title),
                ]))
            return
        }
        CLIOut.out("\(snapshot.title): \(snapshot.detail)")
    }
}

struct CameraExtensionStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Read whether Edith Camera is installed.",
        discussion: """
            Reads whether Edith Camera is installed. This is Check again in the camera
            inspector. Example: `ed camera extension status --json`.
            """)

    @Flag(name: .long, help: "Emit the extension status as JSON.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            CameraExtensionCLI.emit(try await CameraExtensionCLI.request(.status), json: json)
        }
    }
}

struct CameraExtensionInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Ask macOS to install the Edith Camera extension.",
        discussion: """
            Previews the install, then --yes writes the system extension request from the
            Edith app. macOS may still ask you to approve it.
            Example: `ed camera extension install --yes`.
            """)

    @Flag(name: .long, help: "Install after printing the plan.")
    var yes = false

    @Flag(name: .long, help: "Emit the plan, or the extension status, as JSON.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let plan = CLIDestructivePlan(
                action: "install Edith Camera", targets: ["Edith Camera"], confirmed: yes,
                json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await CameraExtensionCLI.request(.install)
            if json {
                CameraExtensionCLI.emit(snapshot, json: true)
            } else {
                plan.finish(changed: snapshot.changed, plain: snapshot.title)
            }
        }
    }
}

struct CameraExtensionRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Ask macOS to remove the Edith Camera extension.",
        discussion: """
            Previews the removal, then --yes writes that request from the Edith app.
            Example: `ed camera extension remove --yes`.
            """)

    @Flag(name: .long, help: "Remove the extension after printing the plan.")
    var yes = false

    @Flag(name: .long, help: "Emit the plan, or the extension status, as JSON.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let plan = CLIDestructivePlan(
                action: "remove Edith Camera", targets: ["Edith Camera"], confirmed: yes,
                json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await CameraExtensionCLI.request(.remove)
            if json {
                CameraExtensionCLI.emit(snapshot, json: true)
            } else {
                plan.finish(changed: snapshot.changed, plain: snapshot.title)
            }
        }
    }
}
