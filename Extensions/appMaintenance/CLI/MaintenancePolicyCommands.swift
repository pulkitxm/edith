import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

enum MaintenancePolicyCLI {
    static func ignore(
        id: String, version: String, persistence: AppUpdatePersistence = AppUpdatePersistence()
    ) throws -> AppUpdateCenterState {
        var state = persistence.load()
        state.ignoredVersions[id] = version
        try persistence.save(state)
        return state
    }

    static func snooze(
        id: String, until: Date, persistence: AppUpdatePersistence = AppUpdatePersistence()
    ) throws -> AppUpdateCenterState {
        var state = persistence.load()
        state.snoozedUntil[id] = until
        try persistence.save(state)
        return state
    }

    static func exclude(
        bundleID: String, persistence: AppUpdatePersistence = AppUpdatePersistence()
    ) throws -> AppUpdateCenterState {
        var state = persistence.load()
        state.excludedBundleIDs.insert(bundleID)
        try persistence.save(state)
        return state
    }

    static func reset(persistence: AppUpdatePersistence = AppUpdatePersistence()) throws
        -> AppUpdateCenterState
    {
        var state = persistence.load()
        state.ignoredVersions = [:]
        state.snoozedUntil = [:]
        state.excludedBundleIDs = []
        try persistence.save(state)
        return state
    }

    static func until(_ raw: String, now: Date = Date()) throws -> Date {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 1, let unit = value.last, let amount = Int(value.dropLast()), amount > 0
        else {
            throw CLIFailure.usage(
                "\(raw) is not a duration like 12h or 7d", hint: "use a number plus m, h or d")
        }
        let seconds: TimeInterval
        switch unit {
        case "m": seconds = Double(amount) * 60
        case "h": seconds = Double(amount) * 3_600
        case "d": seconds = Double(amount) * 86_400
        default:
            throw CLIFailure.usage(
                "\(raw) is not a duration like 12h or 7d", hint: "use a number plus m, h or d")
        }
        return now.addingTimeInterval(seconds)
    }

    static func json(_ state: AppUpdateCenterState) -> JSONValue {
        .object([
            "excluded": .strings(state.excludedBundleIDs.sorted()),
            "ignored": .object(state.ignoredVersions.mapValues(JSONValue.string)),
            "snoozed": .object(
                state.snoozedUntil.mapValues {
                    .string(ISO8601DateFormatter().string(from: $0))
                }),
        ])
    }
}

struct MaintenanceIgnoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ignore",
        abstract: "Ignore one available update version.",
        discussion: """
            Writes the same ignored-version policy the update list uses. Later versions
            of that item still appear. Example: `ed maintenance ignore firefox --available 120.0`.
            """)

    @Flag(name: .long, help: "Emit the policy as JSON.")
    var json = false

    @Option(name: .long, help: "Available version to ignore.")
    var available: String

    @Argument(help: "Update item id from `ed maintenance updates`.")
    var id: String

    @MainActor func run() async throws {
        try await execute {
            let state = try MaintenancePolicyCLI.ignore(id: id, version: available)
            if json {
                CLIOut.json(MaintenancePolicyCLI.json(state))
            } else {
                CLIOut.out("ignored \(id) \(available)")
            }
        }
    }
}

struct MaintenanceSnoozeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snooze",
        abstract: "Hide one update until a duration from now.",
        discussion: """
            Writes the snooze the update list uses. Example: `ed maintenance snooze firefox --for 7d`.
            """)

    @Flag(name: .long, help: "Emit the policy as JSON.")
    var json = false

    @Option(name: .customLong("for"), help: "How long to hide it, such as 12h or 7d.")
    var duration: String

    @Argument(help: "Update item id from `ed maintenance updates`.")
    var id: String

    @MainActor func run() async throws {
        try await execute {
            let until = try MaintenancePolicyCLI.until(duration)
            let state = try MaintenancePolicyCLI.snooze(id: id, until: until)
            if json {
                CLIOut.json(MaintenancePolicyCLI.json(state))
            } else {
                CLIOut.out("snoozed \(id) until \(ISO8601DateFormatter().string(from: until))")
            }
        }
    }
}

struct MaintenanceExcludeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exclude",
        abstract: "Stop offering updates for one bundle identifier.",
        discussion: """
            Writes the excluded-bundle policy the update list uses.
            Example: `ed maintenance exclude com.example.App`.
            """)

    @Flag(name: .long, help: "Emit the policy as JSON.")
    var json = false

    @Argument(help: "Bundle identifier to exclude.")
    var bundleID: String

    @MainActor func run() async throws {
        try await execute {
            let state = try MaintenancePolicyCLI.exclude(bundleID: bundleID)
            if json {
                CLIOut.json(MaintenancePolicyCLI.json(state))
            } else {
                CLIOut.out("excluded \(bundleID)")
            }
        }
    }
}

struct MaintenanceResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Clear ignored, snoozed and excluded update policy.",
        discussion: """
            Previews the policy, then --yes writes a cleared ignore, snooze, and exclude
            policy. History stays. Example: `ed maintenance reset --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the cleared policy, as JSON.")
    var json = false

    @Flag(name: .long, help: "Clear the policy after printing the plan.")
    var yes = false

    @MainActor func run() async throws {
        try await execute {
            let current = AppUpdatePersistence().load()
            let targets =
                current.ignoredVersions.keys.sorted() + current.excludedBundleIDs.sorted()
            let plan = CLIDestructivePlan(
                action: "reset update policy", targets: targets, confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let state = try MaintenancePolicyCLI.reset()
            if json {
                CLIOut.json(MaintenancePolicyCLI.json(state))
            } else {
                plan.finish(changed: true, plain: "reset update policy")
            }
        }
    }
}
