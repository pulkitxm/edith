import ArgumentParser
import EdithKit
import Foundation

struct MaintenanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maintenance",
        abstract: "Installed app inventory, updates, and review-first removal.",
        discussion: """
            Inventory and scan run locally. Remove prints the exact Trash plan unless
            --yes is present. Only regular apps directly inside Applications are accepted.
            """,
        subcommands: [
            MaintenanceInventoryCommand.self, MaintenanceScanCommand.self,
            MaintenanceRemoveCommand.self, MaintenanceInstallCommand.self,
        ],
        defaultSubcommand: MaintenanceInventoryCommand.self)
}

enum MaintenanceCLI {
    static func applicationURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path.expandingTilde()).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIFailure.notFound("there is no application at \(path)")
        }
        return url
    }

    static func diskImageURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path.expandingTilde()).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIFailure.notFound("there is no disk image at \(path)")
        }
        return url
    }

    static func applicationJSON(_ application: InstalledApplication) -> JSONValue {
        .object([
            "bundleID": .string(application.bundleID),
            "name": .string(application.name),
            "path": .string(application.url.path),
            "update": application.update.map { update in
                .object([
                    "installedVersion": .string(update.installedVersion),
                    "latestVersion": .string(update.latestVersion),
                    "source": .string(update.source),
                ])
            } ?? .null,
            "version": .string(application.version),
        ])
    }

    static func itemJSON(_ item: AppMaintenanceItem) -> JSONValue {
        .object([
            "category": .string(item.category.rawValue),
            "path": .string(item.url.path),
            "sizeBytes": .number(item.sizeBytes),
        ])
    }

    static func planJSON(_ plan: AppMaintenancePlan, selected: [AppMaintenanceItem]) -> JSONValue {
        .object([
            "application": applicationJSON(plan.application),
            "items": .array(plan.items.map(itemJSON)),
            "selectedBytes": .number(selected.reduce(0) { $0 + $1.sizeBytes }),
            "selectedItems": .array(selected.map(itemJSON)),
        ])
    }

    static func installPlanJSON(_ plan: AppMaintenanceDiskImagePlan) -> JSONValue {
        .object([
            "application": applicationJSON(plan.sourceApplication),
            "destination": .string(plan.destination.rawValue),
            "destinationPath": .string(plan.destinationURL.path),
            "diskImage": .string(plan.imageURL.path),
            "diskImageBytes": .number(plan.imageSizeBytes),
            "existingApplication": plan.existingApplication.map(applicationJSON) ?? .null,
            "replacesExisting": .bool(plan.replacesExisting),
            "verified": .bool(true),
        ])
    }

    static func plan(_ path: String) throws -> AppMaintenancePlan {
        do {
            return try AppMaintenanceExecution.plan(applicationURL: applicationURL(path))
        } catch let error as AppMaintenanceError {
            throw CLIFailure(error.localizedDescription)
        }
    }

    static func printPlan(_ plan: AppMaintenancePlan, selected: [AppMaintenanceItem]) {
        CLIOut.out("reviewed \(plan.application.name) (\(plan.application.bundleID))")
        CLIOut.out(
            TextTable.render(
                headers: ["SELECTED", "SIZE", "CATEGORY", "PATH"],
                rows: plan.items.map { item in
                    [
                        selected.contains(where: { $0.id == item.id }) ? "yes" : "no",
                        ByteFormatter.string(item.sizeBytes), item.category.rawValue,
                        item.url.path,
                    ]
                }))
        CLIOut.out("")
        let total = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        CLIOut.out("selected \(selected.count) items, \(ByteFormatter.string(total))")
    }

    static func printInstallPlan(_ plan: AppMaintenanceDiskImagePlan) {
        CLIOut.out("reviewed \(plan.sourceApplication.name) \(plan.sourceApplication.version)")
        CLIOut.out("bundle: \(plan.sourceApplication.bundleID)")
        CLIOut.out("image: \(plan.imageURL.path)")
        CLIOut.out("destination: \(plan.destinationURL.path)")
        CLIOut.out("verification: code signature and Gatekeeper accepted")
        if let existing = plan.existingApplication {
            CLIOut.out("replacement: \(existing.name) \(existing.version) moves to the Trash")
        } else {
            CLIOut.out("replacement: none")
        }
    }
}

struct MaintenanceInventoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inventory",
        abstract: "List installed applications and available Homebrew updates.",
        aliases: ["ls", "list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Skip the optional Homebrew update check.")
    var noUpdates = false

    func run() async throws {
        try await execute {
            let disabledData = noUpdates ? Data() : nil
            let applications = AppMaintenanceInventory.applications(updateData: disabledData)
            guard !json else {
                CLIOut.json(.array(applications.map(MaintenanceCLI.applicationJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "VERSION", "UPDATE", "BUNDLE", "PATH"],
                    rows: applications.map { application in
                        [
                            application.name, application.version,
                            application.update?.latestVersion ?? "",
                            application.bundleID, application.url.path,
                        ]
                    }))
        }
    }
}

struct MaintenanceScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: "Preview an app and its exact support files.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Application path directly inside /Applications or ~/Applications.")
    var application: String

    func run() async throws {
        try await execute {
            let plan = try MaintenanceCLI.plan(application)
            guard !json else {
                CLIOut.json(MaintenanceCLI.planJSON(plan, selected: plan.items))
                return
            }
            MaintenanceCLI.printPlan(plan, selected: plan.items)
        }
    }
}

struct MaintenanceRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Move a reviewed app selection to the Trash.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Move only the application bundle and leave support files in place.")
    var onlyApp = false

    @Flag(help: "Actually move the selection. Without it, print the exact plan.")
    var yes = false

    @Argument(help: "Application path directly inside /Applications or ~/Applications.")
    var application: String

    func run() async throws {
        try await execute {
            let plan = try MaintenanceCLI.plan(application)
            let selected = plan.items.filter { !onlyApp || $0.category == .application }
            guard yes else {
                if json {
                    var preview = MaintenanceCLI.planJSON(plan, selected: selected)
                    if case var .object(object) = preview {
                        object["applied"] = .bool(false)
                        preview = .object(object)
                    }
                    CLIOut.json(preview)
                } else {
                    MaintenanceCLI.printPlan(plan, selected: selected)
                    CLIOut.note("pass --yes to move this selection to the Trash")
                }
                return
            }
            let result: AppMaintenanceRemovalResult
            do {
                result = try AppMaintenanceExecution.remove(
                    plan: plan, selectedIDs: Set(selected.map(\.id)))
            } catch let error as AppMaintenanceError {
                throw CLIFailure(error.localizedDescription)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "applied": .bool(true),
                        "failed": .array(result.failed.map(MaintenanceCLI.itemJSON)),
                        "reclaimedBytes": .number(result.reclaimedBytes),
                        "removed": .array(result.removed.map(MaintenanceCLI.itemJSON)),
                    ]))
                return
            }
            CLIOut.out(
                "moved \(result.removed.count) items, \(ByteFormatter.string(result.reclaimedBytes)), to the Trash"
            )
            if !result.failed.isEmpty {
                CLIOut.note("\(result.failed.count) reviewed items could not be moved")
            }
        }
    }
}

struct MaintenanceInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Verify and install the single app inside a disk image.",
        discussion: """
            The image is mounted read-only, and the one top-level app must pass code-signing
            and Gatekeeper checks. Without --yes, the image is ejected after printing the plan.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Install in /Applications instead of ~/Applications.")
    var system = false

    @Flag(help: "Move an existing app with the same bundle ID to the Trash.")
    var replace = false

    @Flag(help: "Keep the disk image after a successful installation.")
    var keepImage = false

    @Flag(help: "Apply the reviewed installation plan.")
    var yes = false

    @Argument(help: "Path to a disk image containing one top-level application.")
    var diskImage: String

    func run() async throws {
        try await execute {
            let destination =
                system
                ? AppMaintenanceInstallDestination.system : .user
            let plan: AppMaintenanceDiskImagePlan
            do {
                plan = try await AppMaintenanceDiskImageInstaller.plan(
                    imageURL: MaintenanceCLI.diskImageURL(diskImage),
                    destination: destination)
            } catch let error as AppMaintenanceDiskImageError {
                throw CLIFailure(error.localizedDescription)
            }
            guard yes else {
                if json {
                    var preview = MaintenanceCLI.installPlanJSON(plan)
                    if case var .object(object) = preview {
                        object["applied"] = .bool(false)
                        preview = .object(object)
                    }
                    CLIOut.json(preview)
                } else {
                    MaintenanceCLI.printInstallPlan(plan)
                    CLIOut.note("pass --yes to install this verified application")
                    if plan.replacesExisting {
                        CLIOut.note("pass --replace with --yes to move the existing app to Trash")
                    }
                }
                await AppMaintenanceDiskImageInstaller.cancel(plan: plan)
                return
            }
            if plan.replacesExisting, !replace {
                await AppMaintenanceDiskImageInstaller.cancel(plan: plan)
                throw CLIFailure(
                    "the destination already contains this app",
                    hint: "review the plan, then pass --replace with --yes")
            }
            let result: AppMaintenanceInstallResult
            do {
                result = try await AppMaintenanceDiskImageInstaller.install(
                    plan: plan, replaceExisting: replace,
                    moveImageToTrash: !keepImage)
            } catch let error as AppMaintenanceDiskImageError {
                throw CLIFailure(error.localizedDescription)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "applied": .bool(true),
                        "applicationPath": .string(result.applicationURL.path),
                        "diskImageMovedToTrash": .bool(result.imageMovedToTrash),
                        "ejected": .bool(result.ejected),
                        "replacedExisting": .bool(result.replacedExisting),
                    ]))
                return
            }
            CLIOut.out("installed \(result.applicationURL.path)")
            if !result.ejected {
                CLIOut.note("the app is installed, but the disk image is still mounted")
            } else if !keepImage, !result.imageMovedToTrash {
                CLIOut.note("the app is installed, but the disk image was kept")
            }
        }
    }
}
