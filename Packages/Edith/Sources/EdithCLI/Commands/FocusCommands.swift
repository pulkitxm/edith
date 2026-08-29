import ArgumentParser
import EdithCore
import EdithKit
import Foundation

struct FocusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus", abstract: "Run focus profiles and Meeting Mode.",
        subcommands: [
            FocusListCommand.self, FocusStatusCommand.self, FocusStartCommand.self,
            FocusStopCommand.self, FocusHistoryCommand.self,
        ], defaultSubcommand: FocusStatusCommand.self)
}

enum FocusCLI {
    static var storage: FocusStorage {
        let root =
            ProcessInfo.processInfo.environment["EDITH_FOCUS_ROOT"]
            .map(URL.init(fileURLWithPath:)) ?? AppDirectories.current.data
        return FocusStorage(root: root)
    }

    static func durationMinutes(_ raw: String) throws -> Int {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 1, let unit = value.last, let amount = Double(value.dropLast()),
            amount > 0
        else { throw CLIFailure.usage("\(raw) is not a duration like 25m, 1h or 90m") }
        let minutes = unit == "h" ? amount * 60 : unit == "m" ? amount : 0
        guard minutes > 0, minutes <= Double(Int.max), minutes.rounded() == minutes else {
            throw CLIFailure.usage("\(raw) is not a whole number of minutes")
        }
        return Int(minutes)
    }

    static func untilDate(_ raw: String, now: Date = Date()) throws -> Date {
        if let date = ISO8601DateFormatter().date(from: raw), date > now { return date }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else {
            throw CLIFailure.usage("\(raw) is not a future ISO date or local time like 17:30")
        }
        let calendar = Calendar.current
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
        else { throw CLIFailure.usage("\(raw) is not a valid local time") }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)!
    }

    static func request(
        action: String, profile: String? = nil, durationMinutes: Int? = nil,
        until: Date? = nil
    ) async throws -> [AnyHashable: Any] {
        try AppBridge.requireHelper("Focus Profiles")
        let requestID = UUID().uuidString
        var payload: [String: Any] = [
            "requestID": requestID, "action": action,
            "origin": FocusActivationOrigin.commandLine.rawValue,
        ]
        if let profile { payload["profile"] = profile }
        if let durationMinutes { payload["durationMinutes"] = durationMinutes }
        if let until { payload["until"] = ISO8601DateFormatter().string(from: until) }
        let requestPayload = payload
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.focusActionResult, timeout: 180,
                matching: { $0["requestID"] as? String == requestID },
                trigger: { AppBridge.post(IPC.Name.requestFocusAction, userInfo: requestPayload) })
        else {
            throw AppBridge.silence(
                "Focus Profiles", extensionKey: AppStorageKeys.Focus.enabled)
        }
        guard reply["succeeded"] as? Bool == true else {
            throw CLIFailure(reply["error"] as? String ?? "The focus action failed")
        }
        return reply
    }

    static func sessionJSON(_ session: FocusSession?) -> JSONValue {
        guard let session else { return .null }
        return .object([
            "id": .string(session.id.uuidString), "profile": .string(session.profileName),
            "profileID": .string(session.profileID.uuidString),
            "origin": .string(session.origin.rawValue), "startedAt": .date(session.startedAt),
            "endsAt": .date(session.endsAt),
            "meeting": .bool(session.meetingEventIdentifier != nil),
        ])
    }

    static func replyJSON(_ reply: [AnyHashable: Any]) -> JSONValue {
        var value: [String: JSONValue] = [
            "active": .bool(reply["profile"] != nil),
            "profile": .optional(reply["profile"] as? String),
            "startedAt": .optional(reply["startedAt"] as? String),
            "endsAt": .optional(reply["endsAt"] as? String),
        ]
        value["succeeded"] = .bool(reply["succeeded"] as? Bool == true)
        return .object(value)
    }
}

struct FocusListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List configured focus profiles.", aliases: ["list"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() throws {
        let document = try FocusCLI.storage.load()
        if json {
            let data = try JSONEncoder().encode(document.profiles)
            CLIOut.out(String(decoding: data, as: UTF8.self))
            return
        }
        guard !document.profiles.isEmpty else {
            CLIOut.note("no focus profiles configured"); return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["NAME", "STATE", "SCENES", "DURATION"],
                rows: document.profiles.map {
                    [
                        $0.name, $0.isEnabled ? "enabled" : "disabled",
                        String($0.sceneIDs.count + ($0.windowLayoutSceneID == nil ? 0 : 1)),
                        $0.defaultDurationMinutes.map { "\($0)m" } ?? "until stopped",
                    ]
                }))
    }
}

struct FocusStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show the active focus session.")
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        if AppBridge.helperIsRunning {
            let reply = try await FocusCLI.request(action: "status")
            if json {
                CLIOut.json(FocusCLI.replyJSON(reply))
            } else {
                CLIOut.out((reply["profile"] as? String).map { "active: \($0)" } ?? "inactive")
            }
            return
        }
        let session = try FocusCLI.storage.session()
        if json {
            CLIOut.json(FocusCLI.sessionJSON(session))
        } else {
            CLIOut.out(session.map { "active: \($0.profileName)" } ?? "inactive")
        }
    }
}

struct FocusStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start a focus profile.")
    @Argument(help: "Profile name or id.") var profile: String
    @Option(name: .customLong("for"), help: "Duration such as 25m, 1h or 90m.") var duration:
        String?
    @Option(help: "End at a future ISO date or local time like 17:30.") var until: String?
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        guard duration == nil || until == nil else {
            throw CLIFailure.usage("--for and --until cannot be used together")
        }
        let reply = try await FocusCLI.request(
            action: "start", profile: profile,
            durationMinutes: try duration.map(FocusCLI.durationMinutes),
            until: try until.map { try FocusCLI.untilDate($0) })
        if json { CLIOut.json(FocusCLI.replyJSON(reply)) } else { CLIOut.out("started \(profile)") }
    }
}

struct FocusStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "End focus and restore the prior state.", aliases: ["end"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        let reply = try await FocusCLI.request(action: "stop")
        if json { CLIOut.json(FocusCLI.replyJSON(reply)) } else { CLIOut.out("focus ended") }
    }
}

struct FocusHistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Show recent focus sessions.")
    @Option(name: .long, help: "Show at most this many sessions.") var limit = 20
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() throws {
        let records = Array(try FocusCLI.storage.history().suffix(max(0, limit)).reversed())
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            CLIOut.out(String(decoding: try encoder.encode(records), as: UTF8.self))
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["WHEN", "PROFILE", "SOURCE", "RESULT"],
                rows: records.map {
                    [
                        $0.startedAt.formatted(), $0.profileName, $0.origin.rawValue,
                        $0.outcome.rawValue,
                    ]
                }))
    }
}
