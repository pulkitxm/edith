import ArgumentParser
import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

struct StudioEditRegister: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Register an external project reference without copying or modifying it.",
        discussion: """
            Register an external project reference without copying or modifying it.

            Changes the state this command names.

            ed studio edit register web
            ed studio edit register web --json
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
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
        abstract: "Remove a registered reference, preserving the project and all media.",
        discussion: """
            Remove a registered reference, preserving the project and all media.

            Changes the state this command names.

            ed studio edit unregister web
            ed studio edit unregister web --json
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
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
        abstract: "List native and registered projects, including stale reference errors.",
        discussion: """
            List native and registered projects, including stale reference errors.

            Reads the current state. Does not change it.

            ed studio edit library
            ed studio edit library --json
            """, )
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
            "Open a specific project revision in the running native editor and await its mounted acknowledgment.",
        discussion: """
            Open a specific project revision in the running native editor and await its
            mounted acknowledgment.

            Changes this Mac by opening the target in an app or a browser.

            ed studio edit open web
            ed studio edit open web --json
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
    @Flag(help: "Emit JSON results and runtime errors.") var json = false
    @Option(help: "Seconds to wait for the native editor, from 1 to 120.") var timeout: Double = 30

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            guard timeout.isFinite, (1...120).contains(timeout) else {
                throw VideoEditorService.Failure(
                    "invalid_timeout", "Timeout must be between 1 and 120 seconds.")
            }
            let request = try VideoEditorService.prepareOpen(StudioEditBridge.url(project))
            try await StudioCLIEnvironment.openProject(request, timeout)
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

}

struct StudioEditTrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Move a project document to Trash, preserving all source media and exports.",
        discussion: """
            Move a project document to Trash, preserving all source media and exports.

            Changes the state this command names.

            ed studio edit trash web
            ed studio edit trash web --json
            """,
        aliases: ["delete"])
    @Argument(help: "Local .openscreen project.") var project: String
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
