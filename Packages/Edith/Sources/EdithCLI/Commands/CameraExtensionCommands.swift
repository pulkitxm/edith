import ArgumentParser
import EdithKit
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

enum CameraExtensionCLI {
    static let name = "Edith Camera"

    static func request(_ request: CameraExtensionRequest) async throws -> CameraExtensionSnapshot {
        try AppBridge.requireMainApp(name)
        let timeout: TimeInterval = 8
        let runtime = CameraExtensionRuntimeRequest(
            request: request, deadline: Date().addingTimeInterval(timeout))
        let requestID = runtime.requestID
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.cameraExtensionActionResult, timeout: timeout,
                matching: { $0[CameraExtensionIPC.requestIDKey] as? String == requestID },
                trigger: {
                    AppBridge.post(IPC.Name.requestCameraExtensionAction, userInfo: runtime.payload)
                })
        else { throw AppBridge.silence(name) }
        guard reply[CameraExtensionIPC.okKey] as? Bool == true else {
            throw CLIFailure(
                reply[CameraExtensionIPC.errorKey] as? String
                    ?? "The camera extension request failed")
        }
        guard
            let snapshot = CameraExtensionSnapshot.decode(
                reply[CameraExtensionIPC.snapshotKey] as? String)
        else { throw CLIFailure("Edith sent an unreadable camera extension status") }
        return snapshot
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

    func run() async throws {
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

    func run() async throws {
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

    func run() async throws {
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
