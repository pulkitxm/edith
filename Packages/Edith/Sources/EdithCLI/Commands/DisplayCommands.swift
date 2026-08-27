import ArgumentParser
import EdithKit
import Foundation

struct DisplayCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display",
        abstract: "Control display brightness and sleep power behavior.",
        subcommands: [
            DisplayStatusCommand.self, DisplayBrightnessCommand.self, DisplayXDRCommand.self,
            DisplayBluetoothSleepCommand.self,
        ],
        defaultSubcommand: DisplayStatusCommand.self)
}

enum DisplayCLI {
    static func json(_ snapshot: DisplayPowerSnapshot) -> JSONValue {
        .object([
            "displays": .array(
                snapshot.displays.map { display in
                    .object([
                        "id": .int(Int(display.id)),
                        "name": .string(display.name),
                        "builtIn": .bool(display.builtIn),
                        "method": .string(display.method.rawValue),
                        "brightness": .double(display.brightness),
                    ])
                }),
            "xdrSupported": .bool(snapshot.xdrSupported),
            "xdrBoosting": .bool(snapshot.xdrBoosting),
            "bluetoothSupported": .bool(snapshot.bluetoothSupported),
            "bluetoothOffDuringSleep": .bool(snapshot.bluetoothOffDuringSleep),
            "bluetoothRestorePending": .bool(snapshot.bluetoothRestorePending),
            "updatedAt": .date(snapshot.updatedAt),
        ])
    }

    static func printStatus(_ snapshot: DisplayPowerSnapshot) {
        if snapshot.displays.isEmpty {
            CLIOut.out("displays: none")
        } else {
            let rows = snapshot.displays.map { display in
                [
                    String(display.id), display.name, display.builtIn ? "built-in" : "external",
                    display.method.rawValue,
                    "\(Int((display.brightness * 100).rounded()))%",
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "DISPLAY", "TYPE", "METHOD", "BRIGHTNESS"], rows: rows))
        }
        CLIOut.out(
            "xdr boost: \(snapshot.xdrBoosting ? "on" : "off")"
                + (snapshot.xdrSupported ? "" : " (unsupported)"))
        CLIOut.out(
            "bluetooth during sleep: \(snapshot.bluetoothOffDuringSleep ? "off" : "unchanged")"
                + (snapshot.bluetoothSupported ? "" : " (unsupported)"))
        if snapshot.bluetoothRestorePending {
            CLIOut.out("bluetooth restoration: pending")
        }
    }

    static func wholePercent(_ raw: String) throws -> Int {
        guard let percent = Int(raw), (0...100).contains(percent) else {
            throw CLIFailure("\(raw) is not a whole percentage from 0 through 100")
        }
        return percent
    }
}

struct DisplayStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: DisplayPowerOperation.status.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let snapshot = try DisplayPowerOperationExecution.snapshot(
                defaults: CLIEnvironment.sharedDefaults)
            if json {
                CLIOut.json(DisplayCLI.json(snapshot))
            } else {
                DisplayCLI.printStatus(snapshot)
            }
        }
    }
}

struct DisplayBrightnessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brightness", abstract: DisplayPowerOperation.brightness.descriptor.summary)

    @Argument(help: "A whole percentage from 0 through 100.")
    var level: String

    @Option(help: "Only change the display with this id.")
    var display: UInt32?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let percent = try DisplayCLI.wholePercent(level)
            let levels = try DisplayPowerOperationExecution.setBrightness(
                percent: percent, displayID: display, defaults: CLIEnvironment.sharedDefaults,
                announce: { AppBridge.post(IPC.Name.settingsChanged) })
            if json {
                CLIOut.json(
                    .object([
                        "brightness": .int(percent),
                        "display": display.map { .int(Int($0)) } ?? .null,
                        "targets": .array(levels.keys.sorted().map { .int(Int($0)) }),
                    ]))
            } else if let display {
                CLIOut.out("display \(display) brightness: \(percent)%")
            } else {
                CLIOut.out("display brightness: \(percent)%")
            }
        }
    }
}

struct DisplayXDRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xdr", abstract: DisplayPowerOperation.xdr.descriptor.summary)

    @Argument(help: "A whole percentage from 0 through 100, or off.")
    var level: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let normalized = level.lowercased()
            if ["off", "false", "disabled"].contains(normalized) {
                try DisplayPowerOperationExecution.setXDR(
                    enabled: false, defaults: CLIEnvironment.sharedDefaults,
                    announce: { AppBridge.post(IPC.Name.settingsChanged) })
                if json {
                    CLIOut.json(.object(["enabled": .bool(false), "level": .int(0)]))
                } else {
                    CLIOut.out("xdr boost: off")
                }
                return
            }
            let percent = try DisplayCLI.wholePercent(level)
            try DisplayPowerOperationExecution.setXDR(
                enabled: percent > 0, percent: percent, defaults: CLIEnvironment.sharedDefaults,
                announce: { AppBridge.post(IPC.Name.settingsChanged) })
            if json {
                CLIOut.json(
                    .object(["enabled": .bool(percent > 0), "level": .int(percent)]))
            } else {
                CLIOut.out("xdr boost: \(percent)%")
            }
        }
    }
}

struct DisplayBluetoothSleepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth-sleep",
        abstract: DisplayPowerOperation.bluetoothSleep.descriptor.summary)

    @Argument(help: "One of on or off.")
    var state: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let enabled = BooleanWord.parse(state) else {
                throw CLIFailure("\(state) is not on or off", hint: "pass on, off, true or false")
            }
            DisplayPowerOperationExecution.setBluetoothSleep(
                enabled, defaults: CLIEnvironment.sharedDefaults,
                announce: { AppBridge.post(IPC.Name.settingsChanged) })
            if json {
                CLIOut.json(.object(["enabled": .bool(enabled)]))
            } else {
                CLIOut.out("bluetooth off during sleep: \(enabled ? "on" : "off")")
            }
        }
    }
}
