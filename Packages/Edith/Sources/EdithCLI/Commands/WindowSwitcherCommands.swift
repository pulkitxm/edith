import ArgumentParser
import EdithKit
import Foundation

struct WindowSwitcherCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows", abstract: "Search and activate macOS windows.",
        subcommands: [
            WindowSwitcherListCommand.self, WindowSwitcherShowCommand.self,
            WindowSwitcherActivateCommand.self, WindowSwitcherCycleCommand.self,
        ], defaultSubcommand: WindowSwitcherListCommand.self, aliases: ["window-switcher"])
}

enum WindowSwitcherBridge {
    static func request(
        _ operation: WindowSwitcherOperation, windowID: String? = nil,
        timeout: TimeInterval = 4
    ) async throws -> [WindowSwitcherWindow] {
        try AppBridge.requireHelper("window switching")
        let requestID = UUID().uuidString
        var request: [String: Any] = [
            WindowSwitcherIPC.requestIDKey: requestID,
            WindowSwitcherIPC.operationKey: operation.rawValue,
        ]
        if let windowID { request[WindowSwitcherIPC.windowIDKey] = windowID }
        let info = request
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.windowSwitcherOperationResult, timeout: timeout,
                matching: {
                    $0[WindowSwitcherIPC.requestIDKey] as? String == requestID
                },
                trigger: {
                    AppBridge.post(IPC.Name.requestWindowSwitcherOperation, userInfo: info)
                })
        else {
            throw AppBridge.silence(
                "window switching", extensionKey: AppStorageKeys.WindowSwitcher.enabled,
                permission: "accessibility")
        }
        switch reply[WindowSwitcherIPC.statusKey] as? String {
        case "ok":
            return WindowSwitcherIPC.decode(
                reply[WindowSwitcherIPC.payloadKey] as? String ?? "[]")
        case "extensionOff":
            throw CLIFailure.unavailable(
                "the Window Switcher extension is off",
                hint: "run `ed extensions setup windowSwitcher`")
        case "notAuthorized":
            throw CLIFailure.unavailable(
                "macOS has not granted Edith Accessibility access",
                hint: "run `ed permissions request accessibility`")
        case "notFound":
            throw CLIFailure.notFound(
                windowID.map { "no window with id \($0)" } ?? "no switchable window found",
                hint: "run `ed windows ls --json` and retry")
        default:
            throw CLIFailure.usage("the window switcher rejected the operation")
        }
    }
}

struct WindowSwitcherListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List switchable windows.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let windows = try await WindowSwitcherBridge.request(.list)
            guard !json else {
                CLIOut.json(
                    .array(
                        windows.map { window in
                            .object([
                                "id": .string(window.id),
                                "app": .string(window.appName),
                                "bundleIdentifier": .string(window.bundleIdentifier),
                                "title": .string(window.displayTitle),
                                "minimized": .bool(window.isMinimized),
                                "pid": .int(Int(window.pid)),
                            ])
                        }))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "APP", "WINDOW", "STATE"],
                    rows: windows.map {
                        [
                            $0.id, $0.appName, $0.displayTitle,
                            $0.isMinimized ? "minimized" : "open",
                        ]
                    }))
        }
    }
}

struct WindowSwitcherShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Open the searchable switcher.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            _ = try await WindowSwitcherBridge.request(.show)
            if json {
                CLIOut.json(.object(["action": .string("show"), "opened": .bool(true)]))
            } else {
                CLIOut.out("opened Window Switcher")
            }
        }
    }
}

struct WindowSwitcherActivateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activate", abstract: "Activate one window.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Window ID from `ed windows ls`.")
    var window: String

    func run() async throws {
        try await execute {
            _ = try await WindowSwitcherBridge.request(.activate, windowID: window)
            if json {
                CLIOut.json(
                    .object([
                        "action": .string("activate"), "id": .string(window),
                        "activated": .bool(true),
                    ]))
            } else {
                CLIOut.out("activated \(window)")
            }
        }
    }
}

struct WindowSwitcherCycleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cycle", abstract: "Cycle windows of the front application.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            _ = try await WindowSwitcherBridge.request(.cycle)
            if json {
                CLIOut.json(.object(["action": .string("cycle"), "cycled": .bool(true)]))
            } else {
                CLIOut.out("cycled front application windows")
            }
        }
    }
}
