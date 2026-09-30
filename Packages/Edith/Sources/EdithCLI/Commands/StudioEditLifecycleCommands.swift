import ArgumentParser
import Edith
import EdithKit
import Foundation

struct StudioEditRegister: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Register an external project reference without copying or modifying it.")
    @Argument var project: String
    @Flag(help: "Emit JSON results and runtime errors.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let entry = try VideoEditorService.register(StudioEditBridge.url(project))
            try StudioEditLifecycleOutput.printValue(
                entry, json: json, text: "registered: \(entry.path)")
        }
    }
}

struct StudioEditUnregister: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unregister",
        abstract: "Remove a registered reference, preserving the project and all media.")
    @Argument var project: String
    @Flag(help: "Emit JSON results and runtime errors.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let entry = try VideoEditorService.unregister(StudioEditBridge.url(project))
            try StudioEditLifecycleOutput.printValue(
                entry, json: json, text: "unregistered: \(entry.path)")
        }
    }
}

struct StudioEditLibrary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library",
        abstract: "List native and registered projects, including stale reference errors.")
    @Flag(help: "Emit JSON results and runtime errors.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let entries = try VideoEditorService.library()
            try StudioEditLifecycleOutput.printValue(
                entries, json: json,
                text: entries.map {
                    "\($0.path)\t\($0.title)\t\($0.errorCode ?? "available")"
                }.joined(separator: "\n"))
        }
    }
}

struct StudioEditOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract:
            "Open a specific project revision in the running native editor and await its mounted acknowledgment."
    )
    @Argument var project: String
    @Flag(help: "Emit JSON results and runtime errors.") var json = false
    @Option(help: "Seconds to wait for the native editor, from 1 to 120.") var timeout: Double = 30

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            guard timeout.isFinite, (1...120).contains(timeout) else {
                throw VideoEditorService.Failure(
                    "invalid_timeout", "Timeout must be between 1 and 120 seconds.")
            }
            let request = try VideoEditorService.prepareOpen(StudioEditBridge.url(project))
            guard AppBridge.mainAppIsRunning else {
                throw StudioEditOpen.silenceFailure()
            }
            let deadline = Date().addingTimeInterval(timeout).timeIntervalSince1970
            guard
                let reply = await AppBridge.awaitReply(
                    IPC.Name.videoEditorOpenResult, timeout: timeout,
                    waitingMessage: json
                        ? nil : "waiting for the native editor to open this project...",
                    matching: { request.matches($0) },
                    trigger: {
                        var payload: [String: Any] = request.payload
                        payload["deadline"] = deadline
                        AppBridge.post(IPC.Name.requestVideoEditorOpen, userInfo: payload)
                    })
            else {
                throw StudioEditOpen.silenceFailure()
            }
            guard reply["ok"] as? Bool == true, reply["state"] as? String == "opened" else {
                throw VideoEditorService.Failure(
                    reply["code"] as? String ?? "open_failed",
                    reply["error"] as? String
                        ?? "The native editor did not confirm this project was opened.")
            }
            if json {
                var result: [String: Any] = request.payload
                result["version"] = 1
                result["ok"] = true
                result["state"] = "opened"
                let data = try JSONSerialization.data(
                    withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                CLIOut.out(String(decoding: data, as: UTF8.self))
            } else {
                CLIOut.out("opened: \(request.path) (\(request.revision))")
            }
        }
    }

    static func silenceFailure() -> VideoEditorService.Failure {
        guard AppBridge.mainAppIsRunning else {
            return VideoEditorService.Failure(
                "app_not_running", "Open this CLI's matching Edith app, then retry.")
        }
        return VideoEditorService.Failure(
            "open_timeout",
            "No matching native editor acknowledgment arrived before the deadline. The matching Edith app is running; retry or reopen it."
        )
    }
}

struct StudioEditTrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Move a project document to Trash, preserving all source media and exports.",
        aliases: ["delete"])
    @Argument var project: String
    @Flag(help: "Validate without moving the project or changing its registration.") var dryRun =
        false
    @Flag(help: "Emit JSON results and runtime errors.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let receipt = try await VideoEditorService.trashProject(
                StudioEditBridge.url(project), dryRun: dryRun)
            try StudioEditLifecycleOutput.printValue(
                receipt, json: json,
                text: receipt.written ? "trashed: \(receipt.path)" : "validated: \(receipt.path)")
        }
    }
}

private enum StudioEditLifecycleOutput {
    static func printValue<T: Encodable>(_ value: T, json: Bool, text: String) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            CLIOut.out(String(decoding: try encoder.encode(value), as: UTF8.self))
        } else {
            CLIOut.out(text)
        }
    }
}
