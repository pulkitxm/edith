import ArgumentParser
import EdithKit
import Foundation

struct AudioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio", abstract: "Audio devices, defaults, and application routes.",
        subcommands: [
            AudioStatusCommand.self, AudioInputCommand.self, AudioOutputCommand.self,
            AudioRouteCommand.self,
        ], defaultSubcommand: AudioStatusCommand.self)
}

enum AudioCLI {
    static func snapshot() throws -> AudioDeviceSnapshot {
        do {
            return try CLIEnvironment.audioSnapshot()
        } catch {
            throw CLIFailure.unavailable(
                "audio devices are unavailable", hint: error.localizedDescription)
        }
    }

    static func device(
        named value: String, in devices: [AudioDeviceDescriptor], kind: String
    ) throws -> AudioDeviceDescriptor {
        guard let device = AudioDeviceOperations.resolve(value, among: devices) else {
            throw CLIFailure.notFound(
                "no (kind) device matches \(value)",
                hint: devices.isEmpty
                    ? "connect an audio device and try again"
                    : "available: " + devices.map(\.name).joined(separator: ", "))
        }
        return device
    }

    static func routes(defaults: UserDefaults = CLIEnvironment.sharedDefaults) -> [String: String] {
        AudioControlPolicy.routeMap(
            defaults.dictionary(forKey: AppStorageKeys.Audio.appOutputRoutes))
    }

    static func writeRoutes(
        _ routes: [String: String], defaults: UserDefaults = CLIEnvironment.sharedDefaults
    ) {
        defaults.set(routes, forKey: AppStorageKeys.Audio.appOutputRoutes)
        defaults.synchronize()
        ConfigStore.announceChange()
    }

    static func json(
        snapshot: AudioDeviceSnapshot, routes: [String: String], preferredInputUID: String?
    ) -> JSONValue {
        let devices = snapshot.devices.map { device in
            JSONValue.object([
                "uid": .string(device.uid), "name": .string(device.name),
                "input": .bool(device.supportsInput), "output": .bool(device.supportsOutput),
                "headphones": .bool(device.isHeadphones),
                "defaultInput": .bool(device.isDefaultInput),
                "defaultOutput": .bool(device.isDefaultOutput),
            ])
        }
        return .object([
            "defaultInputUID": .optional(snapshot.defaultInputUID),
            "defaultOutputUID": .optional(snapshot.defaultOutputUID),
            "preferredInputUID": .optional(preferredInputUID),
            "routes": .object(routes.mapValues(JSONValue.string)),
            "devices": .array(devices),
        ])
    }

    static func output(
        snapshot: AudioDeviceSnapshot, routes: [String: String], preferredInputUID: String?,
        json: Bool
    ) {
        guard !json else {
            CLIOut.json(
                self.json(
                    snapshot: snapshot, routes: routes, preferredInputUID: preferredInputUID))
            return
        }
        let input = snapshot.inputs.first { $0.uid == snapshot.defaultInputUID }
        let output = snapshot.outputs.first { $0.uid == snapshot.defaultOutputUID }
        CLIOut.out("input   " + (input?.name ?? "unavailable"))
        CLIOut.out("output  " + (output?.name ?? "unavailable"))
        CLIOut.out(
            "pin     "
                + (preferredInputUID.flatMap { uid in snapshot.inputs.first { $0.uid == uid }?.name
                } ?? "system"))
        CLIOut.out("routes  \(routes.count)")
    }
}

struct AudioStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show devices, defaults, and saved routes.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let snapshot = try AudioCLI.snapshot()
            AudioCLI.output(
                snapshot: snapshot, routes: AudioCLI.routes(),
                preferredInputUID: CLIEnvironment.sharedDefaults.string(
                    forKey: AppStorageKeys.Audio.preferredInputUID), json: json)
        }
    }
}

struct AudioInputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input", abstract: "Pin an input device, or follow the system default.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "An input device name or UID, or `system`.") var device: String

    func run() async throws {
        try await execute {
            let defaults = CLIEnvironment.sharedDefaults
            if device.caseInsensitiveCompare("system") == .orderedSame {
                defaults.removeObject(forKey: AppStorageKeys.Audio.preferredInputUID)
                defaults.synchronize()
                ConfigStore.announceChange()
            } else {
                let snapshot = try AudioCLI.snapshot()
                let selected = try AudioCLI.device(
                    named: device, in: snapshot.inputs, kind: "input")
                do {
                    try CLIEnvironment.setAudioInput(selected.uid)
                } catch {
                    throw CLIFailure.unavailable(
                        "could not select \(selected.name)", hint: error.localizedDescription)
                }
                defaults.set(selected.uid, forKey: AppStorageKeys.Audio.preferredInputUID)
                defaults.synchronize()
                ConfigStore.announceChange()
            }
            let updated = try AudioCLI.snapshot()
            AudioCLI.output(
                snapshot: updated, routes: AudioCLI.routes(),
                preferredInputUID: defaults.string(
                    forKey: AppStorageKeys.Audio.preferredInputUID), json: json)
        }
    }
}

struct AudioOutputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "output", abstract: "Switch the system output device.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "An output device name or UID.") var device: String

    func run() async throws {
        try await execute {
            guard device.caseInsensitiveCompare("system") != .orderedSame else {
                throw CLIFailure.usage(
                    "system is not an output device",
                    hint: "choose one of the devices from `ed audio status`")
            }
            let snapshot = try AudioCLI.snapshot()
            let selected = try AudioCLI.device(
                named: device, in: snapshot.outputs, kind: "output")
            do {
                try CLIEnvironment.setAudioOutput(selected.uid)
            } catch {
                throw CLIFailure.unavailable(
                    "could not select \(selected.name)", hint: error.localizedDescription)
            }
            ConfigStore.announceChange()
            AudioCLI.output(
                snapshot: try AudioCLI.snapshot(), routes: AudioCLI.routes(),
                preferredInputUID: CLIEnvironment.sharedDefaults.string(
                    forKey: AppStorageKeys.Audio.preferredInputUID), json: json)
        }
    }
}

struct AudioRouteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "route", abstract: "Route an application to an output device.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "The application's bundle identifier.") var bundleID: String
    @Argument(help: "An output device name or UID, or `system`.") var device: String

    func run() async throws {
        try await execute {
            let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.contains(".") else {
                throw CLIFailure.usage(
                    "\(bundleID) is not a bundle identifier",
                    hint: "use a value such as com.example.Player")
            }
            var routes = AudioCLI.routes()
            if device.caseInsensitiveCompare("system") == .orderedSame {
                routes.removeValue(forKey: normalized)
            } else {
                let snapshot = try AudioCLI.snapshot()
                let selected = try AudioCLI.device(
                    named: device, in: snapshot.outputs, kind: "output")
                routes[normalized] = selected.uid
            }
            AudioCLI.writeRoutes(routes)
            let snapshot = try AudioCLI.snapshot()
            guard !json else {
                CLIOut.json(
                    .object([
                        "bundleID": .string(normalized),
                        "outputUID": .optional(routes[normalized]),
                        "routes": .object(routes.mapValues(JSONValue.string)),
                    ]))
                return
            }
            let name =
                routes[normalized].flatMap { uid in
                    snapshot.outputs.first { $0.uid == uid }?.name
                } ?? "system"
            CLIOut.out("\(normalized) -> \(name)")
        }
    }
}
