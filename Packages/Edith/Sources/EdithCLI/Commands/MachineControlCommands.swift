import ArgumentParser
import EdithKit
import Foundation

struct MachinesControlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "control",
        abstract: "Inspect and change live machine controls.",
        subcommands: [
            MachinesControlStatusCommand.self,
            MachinesControlBrightnessCommand.self,
            MachinesControlVolumeCommand.self,
            MachinesControlMuteCommand.self,
            MachinesControlWiFiCommand.self,
            MachinesControlBluetoothCommand.self,
            MachinesControlAirplaneCommand.self,
            MachinesControlDNDCommand.self,
            MachinesControlCaffeinateCommand.self,
            MachinesControlKeyboardLightCommand.self,
        ],
        defaultSubcommand: MachinesControlStatusCommand.self)
}

enum MachineControlSwitch: String, ExpressibleByArgument {
    case on
    case off

    var enabled: Bool { self == .on }
}

final class MachineControlTarget {
    let machine: Machine
    let isLocal: Bool
    private let connection: SSHConnection?

    var remotePlatform: RemoteMachinePlatform? {
        get async { await connection?.remotePlatform }
    }

    init(query: String) async throws {
        if ["local", "this-mac", "thismac"].contains(query.lowercased()) {
            machine = .local
            isLocal = true
            connection = nil
            return
        }
        let machine = try MachineResolver.machine(query)
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        do {
            try await connection.connect()
        } catch {
            throw CLIFailure.unavailable(
                "could not reach \(machine.name): \(error.localizedDescription)",
                hint: "check the machine is awake and reachable, then retry")
        }
        self.machine = machine
        isLocal = false
        self.connection = connection
    }

    func run(
        _ command: String, stdin: Data?, timeout: TimeInterval
    ) async -> Result<String, Error> {
        guard let connection else {
            return await LocalMachineCommandExecution.run(
                command, stdin: stdin, timeout: timeout)
        }
        do {
            let result = try await connection.run(command, stdin: stdin, timeout: timeout)
            let output = result.combinedText
            guard result.succeeded else {
                return .failure(
                    SSHConnectionError.commandFailed(
                        command: command, status: result.status, stderr: output))
            }
            return .success(output)
        } catch {
            return .failure(error)
        }
    }
}

enum MachineControlCLI {
    static func status(machine query: String, json: Bool) async throws {
        let target = try await MachineControlTarget(query: query)
        let platform = await controlPlatform(target)
        let result = await MachineControlOperationExecution.status(platform: platform) {
            command, stdin, timeout in
            await target.run(command, stdin: stdin, timeout: timeout)
        }
        let snapshot = try resolved(result, target: target)
        guard !json else {
            CLIOut.json(statusJSON(target: target, snapshot: snapshot))
            return
        }
        let rows = statusRows(snapshot)
        guard !rows.isEmpty else {
            throw CLIFailure.unavailable(
                "\(target.machine.name) did not report any supported controls")
        }
        CLIOut.out(TextTable.render(headers: ["CONTROL", "VALUE"], rows: rows))
    }

    static func apply(
        _ action: MachineControlAction, machine query: String, json: Bool,
        confirmed: Bool = true
    ) async throws {
        let target = try await MachineControlTarget(query: query)
        let platform = await controlPlatform(target)
        if action.isDisruptive, !confirmed {
            renderPreview(action, target: target, json: json)
            return
        }
        let status = await MachineControlOperationExecution.status(platform: platform) {
            command, stdin, timeout in
            await target.run(command, stdin: stdin, timeout: timeout)
        }
        let snapshot = try resolved(status, target: target)
        let result = await MachineControlOperationExecution.perform(
            action, machineID: target.machine.id, isLocal: target.isLocal,
            platform: snapshot.platform
        ) { command, stdin, timeout in
            await target.run(command, stdin: stdin, timeout: timeout)
        }
        switch result {
        case .success:
            renderApplied(action, target: target, json: json)
        case let .failure(error):
            if action.isDisruptive, PowerOutcome.hostWentAway(error),
                MachineControlCenterCommands.disruptiveOperationStarted(error)
            {
                renderApplied(action, target: target, json: json)
                return
            }
            throw CLIFailure(
                "could not change \(action.operation.descriptor.summary.lowercased()) on \(target.machine.name)",
                hint: PowerOutcome.explain(error))
        }
    }

    private static func resolved(
        _ result: Result<MachineControlSnapshot, Error>, target: MachineControlTarget
    ) throws -> MachineControlSnapshot {
        switch result {
        case let .success(snapshot): return snapshot
        case let .failure(error):
            throw CLIFailure.unavailable(
                "could not read controls from \(target.machine.name)",
                hint: PowerOutcome.explain(error))
        }
    }

    private static func controlPlatform(_ target: MachineControlTarget) async
        -> MachineControlPlatform
    {
        guard !target.isLocal else { return .darwin }
        return MachineControlPlatform(await target.remotePlatform ?? .linux)
    }

    private static func statusRows(_ snapshot: MachineControlSnapshot) -> [[String]] {
        var rows: [[String]] = []
        if let value = snapshot.platform { rows.append(["platform", value.rawValue]) }
        if let value = snapshot.batteryLevel { rows.append(["battery", "\(value)%"]) }
        if let value = snapshot.batteryPluggedIn {
            rows.append(["power", value ? "plugged in" : "battery"])
        }
        if let value = snapshot.brightness { rows.append(["brightness", "\(value)%"]) }
        if let value = snapshot.volume { rows.append(["volume", "\(value)%"]) }
        if let value = snapshot.keyboardBacklight {
            rows.append(["keyboard light", "\(value)%"])
        }
        if let value = snapshot.muted { rows.append(["mute", switchText(value)]) }
        if let value = snapshot.wifiEnabled { rows.append(["Wi-Fi", switchText(value)]) }
        if let value = snapshot.bluetoothEnabled {
            rows.append(["Bluetooth", switchText(value)])
        }
        if let value = snapshot.airplaneMode {
            rows.append(["airplane mode", switchText(value)])
        }
        if let value = snapshot.doNotDisturb {
            rows.append(["Do Not Disturb", switchText(value)])
        }
        if let value = snapshot.caffeinateEnabled {
            rows.append(["Caffeinate", switchText(value)])
        }
        return rows
    }

    private static func statusJSON(
        target: MachineControlTarget, snapshot: MachineControlSnapshot
    ) -> JSONValue {
        .object([
            "machine": .string(target.machine.name),
            "local": .bool(target.isLocal),
            "platform": .optional(snapshot.platform?.rawValue),
            "batteryLevel": .optional(snapshot.batteryLevel),
            "batteryPluggedIn": optional(snapshot.batteryPluggedIn),
            "brightness": .optional(snapshot.brightness),
            "volume": .optional(snapshot.volume),
            "keyboardBacklight": .optional(snapshot.keyboardBacklight),
            "muted": optional(snapshot.muted),
            "wifiEnabled": optional(snapshot.wifiEnabled),
            "bluetoothEnabled": optional(snapshot.bluetoothEnabled),
            "airplaneMode": optional(snapshot.airplaneMode),
            "doNotDisturb": optional(snapshot.doNotDisturb),
            "caffeinateEnabled": optional(snapshot.caffeinateEnabled),
        ])
    }

    private static func renderPreview(
        _ action: MachineControlAction, target: MachineControlTarget, json: Bool
    ) {
        guard !json else {
            CLIOut.json(mutationJSON(action, target: target, applied: false))
            return
        }
        CLIOut.out("would \(description(action)) on \(target.machine.name); pass --yes to apply")
    }

    private static func renderApplied(
        _ action: MachineControlAction, target: MachineControlTarget, json: Bool
    ) {
        guard !json else {
            CLIOut.json(mutationJSON(action, target: target, applied: true))
            return
        }
        CLIOut.out("\(description(action)) on \(target.machine.name)")
    }

    private static func mutationJSON(
        _ action: MachineControlAction, target: MachineControlTarget, applied: Bool
    ) -> JSONValue {
        .object([
            "machine": .string(target.machine.name),
            "local": .bool(target.isLocal),
            "operation": .string(action.operation.descriptor.id.rawValue),
            "value": value(action),
            "applied": .bool(applied),
        ])
    }

    private static func value(_ action: MachineControlAction) -> JSONValue {
        switch action {
        case let .setBrightness(value), let .setVolume(value),
            let .setKeyboardBacklight(value):
            return .int(value)
        case let .setMuted(value), let .setWiFiEnabled(value),
            let .setBluetoothEnabled(value), let .setAirplaneMode(value),
            let .setDoNotDisturb(value), let .setCaffeinateEnabled(value):
            return .bool(value)
        }
    }

    private static func description(_ action: MachineControlAction) -> String {
        switch action {
        case let .setBrightness(value): "set brightness to \(value)%"
        case let .setVolume(value): "set volume to \(value)%"
        case let .setKeyboardBacklight(value): "set keyboard light to \(value)%"
        case let .setMuted(value): value ? "muted audio" : "unmuted audio"
        case let .setWiFiEnabled(value): value ? "turned Wi-Fi on" : "turned Wi-Fi off"
        case let .setBluetoothEnabled(value):
            value ? "turned Bluetooth on" : "turned Bluetooth off"
        case let .setAirplaneMode(value):
            value ? "turned airplane mode on" : "turned airplane mode off"
        case let .setDoNotDisturb(value):
            value ? "turned Do Not Disturb on" : "turned Do Not Disturb off"
        case let .setCaffeinateEnabled(value):
            value ? "turned Caffeinate on" : "turned Caffeinate off"
        }
    }

    private static func switchText(_ enabled: Bool) -> String { enabled ? "on" : "off" }

    private static func optional(_ value: Bool?) -> JSONValue {
        value.map(JSONValue.bool) ?? .null
    }
}

struct MachinesControlStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Read the available live controls.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String

    func run() async throws {
        try await execute { try await MachineControlCLI.status(machine: machine, json: json) }
    }
}

struct MachinesControlBrightnessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brightness", abstract: "Set display brightness.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "Brightness from 0 through 100.") var percent: Int

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setBrightness(try level(percent)), machine: machine, json: json)
        }
    }
}

struct MachinesControlVolumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume", abstract: "Set system output volume.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "Volume from 0 through 100.") var percent: Int

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setVolume(try level(percent)), machine: machine, json: json)
        }
    }
}

struct MachinesControlMuteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute", abstract: "Mute or unmute system audio.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "One of on or off.") var state: MachineControlSwitch

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setMuted(state.enabled), machine: machine, json: json)
        }
    }
}

struct MachinesControlWiFiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wifi", abstract: "Turn Wi-Fi on or off.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Flag(name: .long, help: "Apply a change that may disconnect the machine.") var yes = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "One of on or off.") var state: MachineControlSwitch

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setWiFiEnabled(state.enabled), machine: machine, json: json,
                confirmed: yes || state.enabled)
        }
    }
}

struct MachinesControlBluetoothCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth", abstract: "Turn Bluetooth on or off.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "One of on or off.") var state: MachineControlSwitch

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setBluetoothEnabled(state.enabled), machine: machine, json: json)
        }
    }
}

struct MachinesControlAirplaneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "airplane", abstract: "Turn airplane mode on or off.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Flag(name: .long, help: "Apply a change that may disconnect the machine.") var yes = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "One of on or off.") var state: MachineControlSwitch

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setAirplaneMode(state.enabled), machine: machine, json: json,
                confirmed: yes || !state.enabled)
        }
    }
}

struct MachinesControlDNDCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dnd", abstract: "Turn Do Not Disturb on or off.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "One of on or off.") var state: MachineControlSwitch

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setDoNotDisturb(state.enabled), machine: machine, json: json)
        }
    }
}

struct MachinesControlCaffeinateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "caffeinate", abstract: "Prevent automatic sleep.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "One of on or off.") var state: MachineControlSwitch

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setCaffeinateEnabled(state.enabled), machine: machine, json: json)
        }
    }
}

struct MachinesControlKeyboardLightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyboard-light", abstract: "Set keyboard backlight brightness.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Machine name, or local for this Mac.") var machine: String
    @Argument(help: "Brightness from 0 through 100.") var percent: Int

    func run() async throws {
        try await execute {
            try await MachineControlCLI.apply(
                .setKeyboardBacklight(try level(percent)), machine: machine, json: json)
        }
    }
}

private func level(_ value: Int) throws -> Int {
    guard (0...100).contains(value) else {
        throw CLIFailure.usage("level must be between 0 and 100")
    }
    return value
}
