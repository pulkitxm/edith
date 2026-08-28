import ArgumentParser
import EdithKit
import Foundation

struct RadialCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "radial", abstract: "Show and inspect the Radial Launcher.",
        subcommands: [RadialShowCommand.self, RadialProfileCommand.self],
        defaultSubcommand: RadialProfileCommand.self)
}

struct RadialShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show the launcher at the pointer.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard
                CLIEnvironment.sharedDefaults.bool(
                    forKey: RadialLauncherPreferenceKeys.enabled)
            else {
                throw CLIFailure.unavailable(
                    "the Radial Launcher extension is off",
                    hint: "run `ed extensions enable radialLauncher`")
            }
            try AppBridge.requireHelper("the Radial Launcher")
            AppBridge.post(IPC.Name.requestRadialLauncher)
            if json {
                CLIOut.json(.object(["shown": .bool(true)]))
            } else {
                CLIOut.out("radial launcher shown")
            }
        }
    }
}

struct RadialProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile", abstract: "Print the active launcher profile.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        let profile = RadialLauncherProfileStore.decode(
            CLIEnvironment.sharedDefaults.string(forKey: RadialLauncherPreferenceKeys.profile))
        guard json else {
            let rows = profile.items.enumerated().map { index, item in
                [String(index + 1), item.kind.title, item.name, item.payload]
            }
            CLIOut.out(
                profile.name + "\n"
                    + TextTable.render(
                        headers: ["#", "TYPE", "NAME", "TARGET"], rows: rows))
            return
        }
        CLIOut.json(
            .object([
                "id": .string(profile.id.uuidString), "name": .string(profile.name),
                "items": .array(
                    profile.items.map { item in
                        .object([
                            "id": .string(item.id.uuidString),
                            "kind": .string(item.kind.rawValue), "name": .string(item.name),
                            "symbol": .string(item.effectiveSymbol),
                            "payload": .string(item.payload), "keyCode": .int(item.keyCode),
                            "modifiers": .int(item.modifiers),
                            "configured": .bool(item.isConfigured),
                        ])
                    }),
            ]))
    }
}
