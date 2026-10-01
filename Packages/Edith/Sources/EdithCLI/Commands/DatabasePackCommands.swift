import ArgumentParser
import EdithCore
import EdithDatabase
import Foundation

struct DatabasePackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Install the on-demand database driver executable.",
        discussion: """
            Reads the installed driver executable, writes a verified download into \
            Application Support, or removes that directory. It does not change saved \
            connections.

            ed database pack status
            """,
        subcommands: [
            DatabasePackInstallCommand.self,
            DatabasePackStatusCommand.self,
            DatabasePackRemoveCommand.self,
        ],
        defaultSubcommand: DatabasePackStatusCommand.self)
}

struct DatabasePackInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Download and verify the driver pack for this app version.",
        discussion: """
            Downloads the pack published for this app version, checks its SHA-256 \
            checksum and code signature, then writes the executable into Application \
            Support. A pack built for another version is replaced. Saved connections \
            are not changed.

            ed database pack install
            """)

    @Flag(name: .long, help: "Emit one JSON object on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let progress = CLIProgress.forCommand(json: json)
            progress.begin("installing the database pack")
            let before = DatabasePackCLI.inspection()
            let inspection: DatabasePackInspection
            do {
                inspection = try await DatabaseCLIEnvironment.installPack { fraction in
                    progress.update("downloaded \(Int((fraction * 100).rounded())) percent")
                }
            } catch let failure as CLIFailure {
                throw failure
            } catch {
                throw DatabasePackCLI.failure(error)
            }
            let changed =
                before.state != inspection.state
                || before.installedVersion != inspection.installedVersion
            DatabasePackCLI.emit(inspection, json: json, changed: changed)
            progress.done("database pack is installed")
        }
    }
}

struct DatabasePackStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether the installed driver pack matches this app.",
        discussion: """
            Reads the installed pack and reports its version and whether it matches \
            this app. It does not change the pack, saved connections, or the network.

            ed database pack status
            """)

    @Flag(name: .long, help: "Emit one JSON object on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            DatabasePackCLI.emit(DatabasePackCLI.inspection(), json: json, changed: false)
        }
    }
}

struct DatabasePackRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete the installed driver pack from this Mac.",
        discussion: """
            Deletes the installed database pack directory. It does not change saved \
            connections and does not download a replacement.

            ed database pack remove
            """)

    @Flag(name: .long, help: "Emit one JSON object on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let removed: Bool
            do {
                removed = try DatabasePackStore.remove(directories: DatabasePackCLI.directories())
            } catch {
                throw CLIFailure(
                    "the database pack could not be removed",
                    hint: "check that the pack directory is writable")
            }
            DatabasePackCLI.emit(DatabasePackCLI.inspection(), json: json, changed: removed)
        }
    }
}

enum DatabasePackCLI {
    static func directories() -> AppDirectories {
        AppDirectories(
            homeDirectory: CLIEnvironment.homeDirectory,
            directoryName: AppBuildIdentity.directoryName)
    }

    static func inspection() -> DatabasePackInspection {
        DatabasePackStore.inspect(
            expectedVersion: DatabasePackVersion.current(),
            directories: directories())
    }

    static func emit(_ inspection: DatabasePackInspection, json: Bool, changed: Bool) {
        if json {
            CLIOut.json(self.json(inspection, changed: changed))
            return
        }
        CLIOut.out("state     \(inspection.state.rawValue)")
        CLIOut.out("version   \(inspection.installedVersion ?? "-")")
        CLIOut.out("expected  \(inspection.expectedVersion)")
        CLIOut.out("path      \(inspection.path)")
        if changed { CLIOut.out("changed   yes") }
    }

    static func json(_ inspection: DatabasePackInspection, changed: Bool) -> JSONValue {
        .object([
            "changed": .bool(changed),
            "expectedVersion": .string(inspection.expectedVersion),
            "installedVersion": .optional(inspection.installedVersion),
            "path": .string(inspection.path),
            "state": .string(inspection.state.rawValue),
        ])
    }

    static func failure(_ error: Error) -> CLIFailure {
        guard let error = error as? DatabasePackInstallError else {
            return CLIFailure("the database pack could not be installed")
        }
        switch error {
        case .checksumMismatch:
            return CLIFailure(
                "the database pack checksum did not match",
                hint: "run ed database pack install again")
        case .signatureRejected:
            return CLIFailure(
                "the database pack signature was rejected",
                hint: "the pack must be signed with the Edith team identifier")
        case .signatureUnavailable:
            return CLIFailure.unavailable("the database pack signature could not be checked")
        case .archiveInvalid:
            return CLIFailure("the database pack archive could not be read")
        case .downloadFailed:
            return CLIFailure.unavailable(
                "the database pack could not be downloaded",
                hint: "check the network and that this app version has a published pack")
        case .developmentBuild:
            return CLIFailure.unavailable(
                "development builds install the database pack from the local build",
                hint: "run ./build.sh in the worktree")
        }
    }
}
