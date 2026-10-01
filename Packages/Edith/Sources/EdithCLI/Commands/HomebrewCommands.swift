import ArgumentParser
import EdithKit
import Foundation

struct HomebrewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brew",
        abstract: "Search and manage Homebrew formulae and casks.",
        discussion: """
            Homebrew runs noninteractively with automatic updates and analytics disabled.
            Commands have fixed time and output limits, and never request a password.

            Reads the local Homebrew install. install and upgrade change packages. uninstall does not change anything until --yes.

            ed brew ls
            ed brew install ripgrep
            """,
        subcommands: [
            HomebrewStatusCommand.self, HomebrewListCommand.self, HomebrewSearchCommand.self,
            HomebrewInstallCommand.self, HomebrewUpgradeCommand.self,
            HomebrewUninstallCommand.self,
        ],
        defaultSubcommand: HomebrewListCommand.self)
}

enum HomebrewCLI {
    static var client: HomebrewClient { CLIEnvironment.homebrewClient() }

    static func kind(_ raw: String) throws -> HomebrewPackageKind {
        guard let kind = HomebrewPackageKind(rawValue: raw.lowercased()) else {
            throw CLIFailure.usage(
                "unknown Homebrew package kind: \(raw)", hint: "use formula or cask")
        }
        return kind
    }

    static func optionalKind(_ raw: String?) throws -> HomebrewPackageKind? {
        try raw.map(kind)
    }

    static func packageJSON(_ package: HomebrewPackage) -> JSONValue {
        .object([
            "currentVersion": package.currentVersion.map(JSONValue.string) ?? .null,
            "description": package.description.map(JSONValue.string) ?? .null,
            "displayName": .string(package.displayName),
            "homepage": package.homepage.map(JSONValue.string) ?? .null,
            "id": .string(package.id),
            "installed": .bool(package.installed),
            "installedVersions": .strings(package.installedVersions),
            "kind": .string(package.kind.rawValue),
            "name": .string(package.name),
            "outdated": .bool(package.outdated),
        ])
    }

    static func printPackages(_ packages: [HomebrewPackage], json: Bool) {
        guard !json else {
            CLIOut.json(.array(packages.map(packageJSON)))
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["STATUS", "KIND", "NAME", "VERSION", "DESCRIPTION"],
                rows: packages.map { package in
                    [
                        package.outdated ? "update" : package.installed ? "installed" : "available",
                        package.kind.rawValue, package.name, package.versionSummary,
                        package.description ?? "",
                    ]
                }))
    }

    static func mutate(
        _ action: HomebrewMutation, name: String, kind: HomebrewPackageKind, json: Bool
    ) async throws {
        do {
            let result = try await client.mutate(action, kind: kind, name: name)
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string(action.rawValue),
                        "changed": .bool(true),
                        "kind": .string(kind.rawValue),
                        "name": .string(name),
                        "output": .string(result.output),
                    ]))
                return
            }
            CLIOut.out("completed \(action.rawValue) for \(kind.rawValue) \(name)")
            if !result.output.isEmpty { CLIOut.out(result.output) }
        } catch {
            throw failure(error)
        }
    }

    static func failure(_ error: Error) -> CLIFailure {
        guard let failure = error as? HomebrewFailure else {
            return CLIFailure(error.localizedDescription)
        }
        switch failure {
        case .unavailable:
            return .unavailable(
                "Homebrew is not installed.", hint: "install it from https://brew.sh and retry")
        case .invalidQuery, .invalidToken:
            return .usage(failure.localizedDescription)
        case let .commandFailed(_, detail):
            let asksForPassword =
                detail.localizedCaseInsensitiveContains("password")
                || detail.localizedCaseInsensitiveContains("sudo")
            return CLIFailure(
                failure.localizedDescription,
                hint: asksForPassword
                    ? "run this Homebrew operation in Terminal if it requires authentication" : nil)
        case .timedOut, .outputLimitExceeded:
            return CLIFailure(failure.localizedDescription)
        }
    }
}

struct HomebrewStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Inspect the local Homebrew installation.",
        discussion: """
            Show whether Homebrew is installed and healthy.
            Reads the local brew binary and prefix. Does not change packages.

            ed brew status
            ed brew status --json
            """)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = await HomebrewCLI.client.status()
            guard !json else {
                CLIOut.json(
                    .object([
                        "available": .bool(status.available),
                        "executable": status.executable.map(JSONValue.string) ?? .null,
                        "version": status.version.map(JSONValue.string) ?? .null,
                    ]))
                return
            }
            CLIOut.out(
                status.available ? status.version ?? "Homebrew available" : "Homebrew unavailable")
            if let executable = status.executable { CLIOut.out(executable) }
        }
    }
}

struct HomebrewListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List installed Homebrew packages.",
        discussion: """
            List installed formulae and casks.
            Reads Homebrew's installed set. Does not change packages. --outdated keeps ones with updates.

            ed brew ls
            ed brew ls --outdated --json
            """, aliases: ["list"])

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Limit results to formula or cask.")
    var kind: String?

    @Flag(name: .long, help: "Show only packages with updates.")
    var outdated = false

    func run() async throws {
        try await execute {
            do {
                let packages = try await HomebrewCLI.client.installed(
                    kind: try HomebrewCLI.optionalKind(kind), outdatedOnly: outdated)
                HomebrewCLI.printPackages(packages, json: json)
            } catch {
                throw HomebrewCLI.failure(error)
            }
        }
    }
}

struct HomebrewSearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "Search available Homebrew packages.",
        discussion: """
            Search formulae and casks by name.
            Reads the Homebrew index. Does not change installations.

            ed brew search firefox
            ed brew search ripgrep --json
            """)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Search formula or cask.")
    var kind = HomebrewPackageKind.cask.rawValue

    @Argument(help: "Search text.")
    var query: String

    func run() async throws {
        try await execute {
            do {
                let packages = try await HomebrewCLI.client.search(
                    query, kind: try HomebrewCLI.kind(kind))
                HomebrewCLI.printPackages(packages, json: json)
            } catch {
                throw HomebrewCLI.failure(error)
            }
        }
    }
}

struct HomebrewInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install one exact Homebrew package.",
        discussion: """
            Install one formula or cask by exact name.
            Reads the package name. Changes the Homebrew prefix by installing it. --kind is formula or cask.

            ed brew install ripgrep
            ed brew install firefox --kind cask
            """)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Install a formula or cask.")
    var kind = HomebrewPackageKind.formula.rawValue

    @Argument(help: "Exact package name.")
    var name: String

    func run() async throws {
        try await execute {
            try await HomebrewCLI.mutate(
                .install, name: name, kind: try HomebrewCLI.kind(kind), json: json)
        }
    }
}

struct HomebrewUpgradeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade", abstract: "Upgrade one exact Homebrew package.",
        discussion: """
            Upgrade one installed formula or cask.
            Reads the installed version. Changes that package by upgrading it.

            ed brew upgrade ripgrep
            ed brew upgrade ripgrep --json
            """)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Upgrade a formula or cask.")
    var kind = HomebrewPackageKind.formula.rawValue

    @Argument(help: "Exact package name.")
    var name: String

    func run() async throws {
        try await execute {
            try await HomebrewCLI.mutate(
                .upgrade, name: name, kind: try HomebrewCLI.kind(kind), json: json)
        }
    }
}

struct HomebrewUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Preview or uninstall one exact Homebrew package.",
        discussion: """
            Preview uninstalling one package, then do it with --yes.
            Reads the installed package. Without --yes, does not change anything. With --yes, changes Homebrew by uninstalling it.

            ed brew uninstall ripgrep
            ed brew uninstall ripgrep --yes
            """)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Flag(help: "Actually uninstall the package. Without it, print the exact plan.")
    var yes = false

    @Option(name: .long, help: "Uninstall a formula or cask.")
    var kind = HomebrewPackageKind.formula.rawValue

    @Argument(help: "Exact package name.")
    var name: String

    func run() async throws {
        try await execute {
            let packageKind = try HomebrewCLI.kind(kind)
            let validatedName: String
            do {
                validatedName = try HomebrewValidation.token(name)
            } catch {
                throw HomebrewCLI.failure(error)
            }
            let plan = CLIDestructivePlan(
                action: "uninstall Homebrew \(packageKind.rawValue)", targets: [validatedName],
                confirmed: yes, json: json,
                fields: ["kind": .string(packageKind.rawValue), "name": .string(validatedName)])
            guard plan.shouldApply() else { return }
            do {
                let result = try await HomebrewCLI.client.mutate(
                    .uninstall, kind: packageKind, name: validatedName)
                plan.finish(
                    changed: true,
                    plain: "uninstalled \(packageKind.rawValue) \(validatedName)",
                    fields: ["output": .string(result.output)])
            } catch {
                throw HomebrewCLI.failure(error)
            }
        }
    }
}
