import ArgumentParser
import EdithKit
import Foundation

struct LidAwakeCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lid-awake",
        abstract: "Keep the Mac running with its lid closed.",
        subcommands: [
            LidAwakeStatusCommand.self, LidAwakeOnCommand.self, LidAwakeOffCommand.self,
            LidAwakeBatteryCommand.self, LidAwakeRestoreOnQuitCommand.self,
        ],
        defaultSubcommand: LidAwakeStatusCommand.self)
}

enum LidAwakeCLI {
    static func session(duration: String?, untilLidReopens: Bool) throws -> LidAwakeSession {
        guard !untilLidReopens || duration == nil else {
            throw CLIFailure("--for and --until-lid-reopens cannot be used together")
        }
        if untilLidReopens { return .untilLidReopens }
        guard let duration else { return .indefinite }
        switch duration.lowercased().replacingOccurrences(of: " ", with: "") {
        case "15m", "15min", "15mins", "15minute", "15minutes", "fifteenminutes":
            return .fifteenMinutes
        case "30m", "30min", "30mins", "30minute", "30minutes", "thirtyminutes":
            return .thirtyMinutes
        case "1h", "60m", "60min", "60mins", "1hour", "onehour":
            return .oneHour
        case "2h", "120m", "120min", "120mins", "2hours", "twohours":
            return .twoHours
        default:
            throw CLIFailure(
                "\(duration) is not a Lid Awake session",
                hint: "use 15m, 30m, 1h or 2h")
        }
    }

    static func batteryThreshold(_ raw: String) throws -> Int {
        if ["off", "none", "disabled"].contains(raw.lowercased()) { return 0 }
        guard let threshold = Int(raw), (1...100).contains(threshold) else {
            throw CLIFailure("\(raw) is not a battery percentage from 1 to 100, or off")
        }
        return threshold
    }

    static func request(
        _ action: LidAwakeIPC.Action, session: LidAwakeSession? = nil
    ) async throws -> [AnyHashable: Any] {
        try AppBridge.requireHelper("Lid Awake")
        let timeout: TimeInterval = action == .status ? 3 : 120
        guard let context = LidAwakeRuntimeRequestContext(timeout: .seconds(timeout)) else {
            throw CLIFailure("Lid Awake could not create a valid request deadline")
        }
        var info: [String: Any] = [LidAwakeIPC.actionKey: action.rawValue]
        if let session { info[LidAwakeIPC.sessionKey] = session.rawValue }
        info.merge(context.runtimePayload) { _, new in new }
        let payload = info
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.lidAwakeActionResult, timeout: timeout,
                matching: {
                    $0[LidAwakeIPC.requestIDKey] as? String == context.requestID
                },
                trigger: {
                    AppBridge.post(IPC.Name.requestLidAwakeAction, userInfo: payload)
                })
        else {
            throw AppBridge.silence("Lid Awake", extensionKey: LidAwakeState.enabledKey)
        }
        guard reply[LidAwakeIPC.okKey] as? Bool == true else {
            throw CLIFailure(
                reply[LidAwakeIPC.errorKey] as? String ?? "Lid Awake could not change state")
        }
        return reply
    }

    static func status() async throws -> [AnyHashable: Any] {
        guard AppBridge.helperIsRunning else { return storedStatus() }
        return try await request(.status)
    }

    static func storedStatus() -> [AnyHashable: Any] {
        let defaults = CLIEnvironment.sharedDefaults
        let active = defaults.bool(forKey: LidAwakeState.activeKey)
        return [
            LidAwakeIPC.okKey: true,
            "extensionEnabled": LidAwakeState.isEnabled(defaults),
            "active": active,
            "requestedActive": active,
            "applying": false,
            "batterySuspended": false,
            "session": LidAwakeState.session(defaults).rawValue,
            "batteryThreshold": defaults.integer(forKey: LidAwakeState.batteryThresholdKey),
            "restoreOnQuit": LidAwakeState.restoresOnQuit(defaults),
            "helperStatus": "unavailable",
            "appRunning": false,
        ]
    }

    static func json(_ payload: [AnyHashable: Any]) -> JSONValue {
        .object([
            "extensionEnabled": .bool(payload["extensionEnabled"] as? Bool ?? false),
            "active": .bool(payload["active"] as? Bool ?? false),
            "requestedActive": .bool(payload["requestedActive"] as? Bool ?? false),
            "applying": .bool(payload["applying"] as? Bool ?? false),
            "batterySuspended": .bool(payload["batterySuspended"] as? Bool ?? false),
            "session": .string(payload["session"] as? String ?? "indefinite"),
            "remainingSeconds": .optional(number(payload["remainingSeconds"])),
            "batteryThreshold": .int(payload["batteryThreshold"] as? Int ?? 0),
            "restoreOnQuit": .bool(payload["restoreOnQuit"] as? Bool ?? true),
            "helperStatus": .string(payload["helperStatus"] as? String ?? "unavailable"),
            "appRunning": .bool(payload["appRunning"] as? Bool ?? false),
            "lastError": .optional(payload["lastError"] as? String),
        ])
    }

    static func printStatus(_ payload: [AnyHashable: Any]) {
        let active = payload["active"] as? Bool ?? false
        let suspended = payload["batterySuspended"] as? Bool ?? false
        let applying = payload["applying"] as? Bool ?? false
        let state =
            applying ? "changing" : suspended ? "paused on low battery" : active ? "on" : "off"
        let rawSession = payload["session"] as? String ?? "indefinite"
        let session = LidAwakeSession(rawValue: rawSession) ?? .indefinite
        let threshold = payload["batteryThreshold"] as? Int ?? 0
        CLIOut.out("state: \(state)")
        CLIOut.out("session: \(session.title)")
        if let remaining = number(payload["remainingSeconds"]) {
            CLIOut.out("remaining: \(Int(remaining.rounded(.up))) seconds")
        }
        CLIOut.out("battery auto-pause: \(threshold == 0 ? "off" : "\(threshold)%")")
        CLIOut.out(
            "restore on quit: \((payload["restoreOnQuit"] as? Bool ?? true) ? "on" : "off")")
        CLIOut.out("helper: \(payload["helperStatus"] as? String ?? "unavailable")")
        CLIOut.out("app running: \((payload["appRunning"] as? Bool ?? false) ? "yes" : "no")")
        if let error = payload["lastError"] as? String { CLIOut.out("last error: \(error)") }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

struct LidAwakeStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show the live Lid Awake state.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let payload = try await LidAwakeCLI.status()
            if json {
                CLIOut.json(LidAwakeCLI.json(payload))
            } else {
                LidAwakeCLI.printStatus(payload)
            }
        }
    }
}

struct LidAwakeOnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on", abstract: "Keep running with the lid closed.", aliases: ["start"])

    @Option(name: .customLong("for"), help: "Stop after 15m, 30m, 1h or 2h.")
    var duration: String?

    @Flag(help: "Stop after the lid closes and opens again.")
    var untilLidReopens = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let session = try LidAwakeCLI.session(
                duration: duration, untilLidReopens: untilLidReopens)
            let payload = try await LidAwakeCLI.request(.on, session: session)
            if json {
                CLIOut.json(LidAwakeCLI.json(payload))
            } else {
                CLIOut.out("lid awake on: \(session.title)")
            }
        }
    }
}

struct LidAwakeOffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off", abstract: "Restore normal lid-close sleep.", aliases: ["stop"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let payload = try await LidAwakeCLI.request(.off)
            if json {
                CLIOut.json(LidAwakeCLI.json(payload))
            } else {
                CLIOut.out("lid awake off")
            }
        }
    }
}

struct LidAwakeBatteryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "battery", abstract: "Set the low-battery auto-pause percentage.")

    @Argument(help: "A percentage from 1 to 100, or off.")
    var threshold: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let threshold = try LidAwakeCLI.batteryThreshold(threshold)
            CLIEnvironment.sharedDefaults.set(
                threshold, forKey: LidAwakeState.batteryThresholdKey)
            CLIEnvironment.sharedDefaults.synchronize()
            ConfigStore.announceChange()
            if json {
                CLIOut.json(.object(["batteryThreshold": .int(threshold)]))
            } else {
                CLIOut.out("battery auto-pause = \(threshold == 0 ? "off" : "\(threshold)%")")
            }
        }
    }
}

struct LidAwakeRestoreOnQuitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore-on-quit", abstract: "Choose whether quitting restores normal sleep.")

    @Argument(help: "true or false.")
    var enabled: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let enabled = try ConfigValueParser.boolean(enabled)
            CLIEnvironment.sharedDefaults.set(enabled, forKey: LidAwakeState.restoreOnQuitKey)
            CLIEnvironment.sharedDefaults.synchronize()
            ConfigStore.announceChange()
            if json {
                CLIOut.json(.object(["restoreOnQuit": .bool(enabled)]))
            } else {
                CLIOut.out("restore on quit = \(enabled ? "on" : "off")")
            }
        }
    }
}
