import ArgumentParser
import EdithKit
import Foundation

struct DockCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dock", abstract: "Inspect and open Dock Tools previews.",
        subcommands: [DockStatusCommand.self, DockWindowsCommand.self, DockShowCommand.self],
        defaultSubcommand: DockStatusCommand.self)
}

enum DockCLI {
    static func request(
        operation: String, bundleIdentifier: String? = nil
    ) async throws -> [AnyHashable: Any] {
        try AppBridge.requireHelper("Dock Tools")
        let requestID = UUID().uuidString
        var payload: [String: Any] = [
            DockToolsIPC.requestIDKey: requestID,
            DockToolsIPC.operationKey: operation,
        ]
        if let bundleIdentifier {
            payload[DockToolsIPC.bundleIdentifierKey] = bundleIdentifier
        }
        let requestPayload = payload
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.dockToolsOperationResult, timeout: 3,
                matching: { $0[DockToolsIPC.requestIDKey] as? String == requestID },
                trigger: {
                    AppBridge.post(IPC.Name.requestDockToolsOperation, userInfo: requestPayload)
                })
        else {
            throw AppBridge.silence(
                "Dock Tools", extensionKey: AppStorageKeys.DockTools.enabled)
        }
        switch reply[DockToolsIPC.statusKey] as? String {
        case "ok": return reply
        case "notAuthorized":
            throw CLIFailure.unavailable(
                "Dock Tools needs Accessibility permission",
                hint: "run `ed permissions request accessibility`")
        case "notFound":
            throw CLIFailure.notFound(
                "no running application matches that bundle identifier")
        default:
            throw CLIFailure("Dock Tools rejected the request")
        }
    }

    static func status() async throws -> DockToolsStatus {
        if AppBridge.helperIsRunning {
            let reply = try await request(operation: "status")
            if let payload = reply[DockToolsIPC.payloadKey] as? String,
                let value = DockToolsIPC.decode(DockToolsStatus.self, from: payload)
            {
                return value
            }
        }
        let preferences = DockToolsPreferences(defaults: CLIEnvironment.sharedDefaults)
        let permissions = PermissionOperationCenter(
            environment: .status(defaults: CLIEnvironment.sharedDefaults)
        ).grantedPermissions()
        return DockToolsStatus(
            preferences: preferences, helperRunning: false,
            accessibilityGranted: permissions[.accessibility] == true,
            screenRecordingGranted: permissions[.screenRecording] == true)
    }

    static func json(_ status: DockToolsStatus) -> JSONValue {
        .object([
            "enabled": .bool(status.enabled),
            "ready": .bool(status.ready),
            "helperRunning": .bool(status.helperRunning),
            "accessibilityGranted": .bool(status.accessibilityGranted),
            "screenRecordingGranted": .bool(status.screenRecordingGranted),
            "previewsAvailable": .bool(status.previewsAvailable),
            "previewMode": .string(status.previewMode.rawValue),
            "clickAction": .string(status.clickAction.rawValue),
            "greenButtonMaximizes": .bool(status.greenButtonMaximizes),
            "quitOnLastWindow": .bool(status.quitOnLastWindow),
            "excludedApps": .array(status.excludedApps.map(JSONValue.string)),
        ])
    }

    static func print(_ status: DockToolsStatus) {
        CLIOut.out("state: \(status.ready ? "ready" : status.enabled ? "needs setup" : "disabled")")
        CLIOut.out("helper: \(status.helperRunning ? "running" : "not running")")
        CLIOut.out("accessibility: \(status.accessibilityGranted ? "granted" : "required")")
        CLIOut.out(
            "screen recording: \(status.screenRecordingGranted ? "granted" : "optional")")
        CLIOut.out("previews: \(status.previewMode.title)")
        CLIOut.out("active app click: \(status.clickAction.title)")
        CLIOut.out("excluded apps: \(status.excludedApps.count)")
    }
}

struct DockStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show Dock Tools readiness and behavior.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = try await DockCLI.status()
            json ? CLIOut.json(DockCLI.json(status)) : DockCLI.print(status)
        }
    }
}

struct DockWindowsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows", abstract: "List windows for a running Dock app.")

    @Argument(help: "Bundle identifier, or the frontmost app when omitted.")
    var bundleIdentifier: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let reply = try await DockCLI.request(
                operation: "windows", bundleIdentifier: bundleIdentifier)
            let payload = reply[DockToolsIPC.payloadKey] as? String ?? "[]"
            let windows = DockToolsIPC.decode([DockToolsWindow].self, from: payload) ?? []
            if json {
                CLIOut.out(payload)
                return
            }
            guard !windows.isEmpty else {
                CLIOut.out("no windows")
                return
            }
            for window in windows {
                CLIOut.out("\(window.minimized ? "minimized" : "open")\t\(window.displayTitle)")
            }
        }
    }
}

struct DockShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Open a Dock Tools preview for a running app.")

    @Argument(help: "Bundle identifier, or the frontmost app when omitted.")
    var bundleIdentifier: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            _ = try await DockCLI.request(operation: "show", bundleIdentifier: bundleIdentifier)
            if json {
                CLIOut.json(
                    .object([
                        "shown": .bool(true),
                        "bundleIdentifier": .optional(bundleIdentifier),
                    ]))
            } else {
                CLIOut.out("dock preview shown")
            }
        }
    }
}
