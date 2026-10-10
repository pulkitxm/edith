import ArgumentParser
import AppKit
@_implementationOnly import EdithExtensionCommands
import Foundation

enum AttentionExtensionCLI {
    nonisolated(unsafe) static var repository: () -> AttentionRepository = {
        AttentionCLI.repository
    }
    nonisolated(unsafe) static var copyToken: (String) throws -> Void = { token in
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil else {
            throw CLIFailure.unavailable("Pasteboard actions are unavailable in fixture mode")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    static func payload(
        action: String, path: String? = nil, opened: Bool? = nil, token: String? = nil
    ) -> JSONValue {
        .object([
            "action": .string(action),
            "opened": opened.map { .bool($0) } ?? .null,
            "path": .optional(path),
            "token": .optional(token),
        ])
    }
}

struct AttentionExtensionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extension",
        abstract: "Install, reveal, and open the attention browser extension.",
        discussion: """
            The same folder and browser page as the Attention setup card.
            Reads the bundled extension. install writes the folder. Does not change history by itself.

            ed attention extension install
            """,
        subcommands: [
            AttentionExtensionInstallCommand.self, AttentionExtensionOpenCommand.self,
            AttentionExtensionTokenCommand.self,
        ],
        defaultSubcommand: AttentionExtensionInstallCommand.self)

    @OptionGroup var output: JSONOutputOptions
}

struct AttentionExtensionInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install and reveal the attention browser extension.",
        discussion: """
            Copies the packaged extension into place and shows that folder in Finder.
            This is the Install extension button, which reveals the folder again when it is already there.
            Reads the bundle. Writes the installed folder. Changes which file Finder selects.

            ed attention extension install
            ed attention extension install --json
            """, aliases: ["reveal"])

    @OptionGroup var output: JSONOutputOptions

    func run() async throws {
        try await execute {
            let directory: URL
            do {
                directory = try AttentionExtensionInstaller.install()
                if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil {
                    AttentionExtensionInstaller.revealDirectory(directory)
                }
            } catch {
                throw CLIFailure.unavailable(error.localizedDescription)
            }
            guard !output.json else {
                CLIOut.json(
                    AttentionExtensionCLI.payload(action: "install", path: directory.path))
                return
            }
            CLIOut.out(directory.path)
        }
    }
}

struct AttentionExtensionOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open the browser extensions page.",
        discussion: """
            Opens chrome://extensions, the same way Open extensions does on the setup card.
            Reads nothing stored. Changes which page the browser shows. Does not change attention data.

            ed attention extension open
            ed attention extension open --json
            """)

    @OptionGroup var output: JSONOutputOptions

    func run() async throws {
        try await execute {
            guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil else {
                throw CLIFailure.unavailable("Browser actions are unavailable in fixture mode")
            }
            let opened = AttentionExtensionInstaller.openExtensionsPage()
            guard opened else {
                throw CLIFailure.unavailable("could not open chrome://extensions")
            }
            guard !output.json else {
                CLIOut.json(
                    AttentionExtensionCLI.payload(
                        action: "open", opened: true))
                return
            }
            CLIOut.out("opened chrome://extensions")
        }
    }
}

struct AttentionExtensionTokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Print the attention browser setup token.",
        discussion: """
            Prints the private token the setup card copies into the extension.
            Reads the saved attention settings. With --copy, writes that token to the pasteboard. Does not change the token.

            ed attention extension token
            ed attention extension token --copy --json
            """)

    @Flag(name: .long, help: "Also put the token on the pasteboard.")
    var copy = false

    @OptionGroup var output: JSONOutputOptions

    func run() async throws {
        try await execute {
            let token = AttentionExtensionCLI.repository().loadSettings().serverToken
            if copy { try AttentionExtensionCLI.copyToken(token) }
            guard !output.json else {
                CLIOut.json(AttentionExtensionCLI.payload(action: "token", token: token))
                return
            }
            CLIOut.out(token)
        }
    }
}

struct JSONOutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}
