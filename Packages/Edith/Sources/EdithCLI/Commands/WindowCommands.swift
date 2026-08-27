import ArgumentParser
import EdithKit

struct WindowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window", abstract: "Arrange the active window.",
        subcommands: [
            WindowLeftHalfCommand.self, WindowRightHalfCommand.self, WindowTopHalfCommand.self,
            WindowBottomHalfCommand.self, WindowTopLeftCommand.self, WindowTopRightCommand.self,
            WindowBottomLeftCommand.self, WindowBottomRightCommand.self, WindowCenterCommand.self,
            WindowMaximizeCommand.self, WindowNextDisplayCommand.self, WindowRestoreCommand.self,
        ])
}

private func requestWindowLayout(_ action: WindowLayoutAction, json: Bool) async throws {
    try await execute {
        guard
            CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.WindowTools.enabled)
                as? Bool == true
        else {
            throw CLIFailure.unavailable(
                "the Window Tools extension is off",
                hint: "run `ed extensions enable windowTools`, then retry")
        }
        try AppBridge.requireHelper("arranging a window")
        let descriptor = WindowLayoutRequest.send(action) { AppBridge.post($0, userInfo: $1) }
        if json {
            CLIOut.json(
                .object([
                    "action": .string(action.rawValue),
                    "operation": .string(descriptor.id.rawValue),
                    "requested": .bool(true),
                ]))
        } else {
            CLIOut.out("window \(action.rawValue) requested")
        }
    }
}

struct WindowLeftHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "left-half", abstract: WindowLayoutAction.leftHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.leftHalf, json: json) }
}

struct WindowRightHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "right-half", abstract: WindowLayoutAction.rightHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.rightHalf, json: json) }
}

struct WindowTopHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top-half", abstract: WindowLayoutAction.topHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.topHalf, json: json) }
}

struct WindowBottomHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottom-half", abstract: WindowLayoutAction.bottomHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.bottomHalf, json: json) }
}

struct WindowTopLeftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top-left", abstract: WindowLayoutAction.topLeft.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.topLeft, json: json) }
}

struct WindowTopRightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top-right", abstract: WindowLayoutAction.topRight.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.topRight, json: json) }
}

struct WindowBottomLeftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottom-left", abstract: WindowLayoutAction.bottomLeft.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.bottomLeft, json: json) }
}

struct WindowBottomRightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottom-right", abstract: WindowLayoutAction.bottomRight.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.bottomRight, json: json) }
}

struct WindowCenterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "center", abstract: WindowLayoutAction.center.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.center, json: json) }
}

struct WindowMaximizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maximize", abstract: WindowLayoutAction.maximize.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.maximize, json: json) }
}

struct WindowNextDisplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next-display", abstract: WindowLayoutAction.nextDisplay.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.nextDisplay, json: json) }
}

struct WindowRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: WindowLayoutAction.restore.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.restore, json: json) }
}
