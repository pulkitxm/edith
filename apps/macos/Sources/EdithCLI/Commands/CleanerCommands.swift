import ArgumentParser
import EdithKit
import Foundation

struct CleanerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleaner",
        abstract: "The developer caches the disk cleaner can reclaim.",
        discussion: """
            Scanning walks your home directory, so it runs in this process and needs no
            app. `ed cleaner clean` moves what it finds to the Trash, never deleting in
            place, and refuses to run without --yes so a stray tab cannot cost you a
            build cache.
            """,
        subcommands: [
            CleanerScanCommand.self, CleanerCategoriesCommand.self, CleanerCleanCommand.self,
            CleanerDrivesCommand.self,
        ],
        defaultSubcommand: CleanerScanCommand.self)
}

enum CleanerBridge {
    static var home: URL { CLIEnvironment.homeDirectory }

    static var projectCategoryIDs: [String] {
        var seen: [String] = []
        for target in JunkScanner.projectTargets where !seen.contains(target.categoryID) {
            seen.append(target.categoryID)
        }
        return seen
    }

    static func knownCategoryIDs() -> [String] {
        JunkCatalog.entries.map(\.id) + projectCategoryIDs
    }

    static func categories(only: String?) throws -> [JunkCatalog.Entry] {
        guard let only else { return JunkCatalog.entries }
        guard let found = JunkCatalog.entries.first(where: { $0.id == only }) else {
            guard projectCategoryIDs.contains(only) else {
                throw CLIFailure.notFound(
                    "no cleaner category named \(only)",
                    hint: "categories: " + knownCategoryIDs().joined(separator: ", "))
            }
            throw CLIFailure(
                "\(only) only turns up when a folder is swept for project junk",
                hint: "pass --root, for example `ed cleaner scan --root ~/code --category \(only)`")
        }
        return [found]
    }

    static func roots(_ raw: [String]) throws -> [URL] {
        try raw.map { path in
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw CLIFailure.notFound("there is no folder at \(path)")
            }
            return URL(fileURLWithPath: expanded)
        }
    }

    static func scan(
        _ entries: [JunkCatalog.Entry], roots: [URL], only: String?,
        progress: CLIProgress? = nil
    ) -> [JunkCategory] {
        var found: [JunkCategory] = []
        for entry in entries {
            progress?.update(entry.name)
            if let category = JunkScanner.scanCategory(entry, home: home) {
                found.append(category)
            }
        }
        guard !roots.isEmpty else { return found }
        var swept = JunkScanner.scanProjectJunk(roots: roots) { note in
            progress?.update(note)
        }
        if let only { swept = swept.filter { $0.id == only } }
        found.append(contentsOf: swept)
        return found
    }

    static func json(_ category: JunkCategory) -> JSONValue {
        .object([
            "category": .string(category.id),
            "name": .string(category.name),
            "detail": .string(category.detail),
            "sizeBytes": .number(category.sizeBytes),
            "items": .array(
                category.items.map { item in
                    .object([
                        "name": .string(item.name),
                        "path": .string(item.path.path),
                        "sizeBytes": .number(item.sizeBytes),
                    ])
                }),
        ])
    }
}

struct CleanerCategoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "categories", abstract: "The caches the cleaner knows how to reclaim.",
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard !json else {
                CLIOut.json(
                    .array(
                        JunkCatalog.entries.map { entry in
                            .object([
                                "category": .string(entry.id),
                                "name": .string(entry.name),
                                "detail": .string(entry.detail),
                                "paths": .strings(entry.relativePaths),
                                "onByDefault": .bool(entry.defaultOn),
                            ])
                        }))
                return
            }
            let rows = JunkCatalog.entries.map { entry in
                [entry.id, entry.name, entry.defaultOn ? "default" : "", entry.detail]
            }
            CLIOut.out(
                TextTable.render(headers: ["ID", "NAME", "", "WHAT"], rows: rows))
        }
    }
}

struct CleanerScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: "Measure what could be reclaimed.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only this category.")
    var category: String?

    @Option(
        name: .customLong("root"),
        help: "Also sweep this folder for project junk. Repeat for more than one.")
    var roots: [String] = []

    func run() async throws {
        try await execute {
            let sweep = try CleanerBridge.roots(roots)
            let entries =
                sweep.isEmpty || category == nil
                ? try CleanerBridge.categories(only: category)
                : ((try? CleanerBridge.categories(only: category)) ?? [])
            let progress = CLIProgress.forCommand(json: json)
            progress.begin("scanning")
            let found = CleanerBridge.scan(
                entries, roots: sweep, only: category, progress: progress)
            progress.end()
            let total = found.reduce(Int64(0)) { $0 + $1.sizeBytes }
            guard !json else {
                CLIOut.json(
                    .object([
                        "totalBytes": .number(total),
                        "categories": .array(found.map(CleanerBridge.json)),
                    ]))
                return
            }
            guard !found.isEmpty else {
                CLIOut.note("nothing to reclaim")
                return
            }
            let rows = found.map { category in
                [
                    category.id, ByteFormatter.string(category.sizeBytes),
                    String(category.items.count), category.name,
                ]
            }
            CLIOut.out(TextTable.render(headers: ["ID", "SIZE", "ITEMS", "NAME"], rows: rows))
            CLIOut.out("")
            CLIOut.out("total \(ByteFormatter.string(total))")
        }
    }
}

struct CleanerCleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean", abstract: "Move the scanned caches to the Trash.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only this category.")
    var category: String?

    @Option(
        name: .customLong("root"),
        help: "Also sweep this folder for project junk. Repeat for more than one.")
    var roots: [String] = []

    @Flag(help: "Actually move the files. Without it nothing is touched.")
    var yes = false

    func run() async throws {
        try await execute {
            let sweep = try CleanerBridge.roots(roots)
            let entries =
                sweep.isEmpty || category == nil
                ? try CleanerBridge.categories(only: category)
                : ((try? CleanerBridge.categories(only: category)) ?? [])
            let progress = CLIProgress.forCommand(json: json)
            progress.begin("scanning")
            let found = CleanerBridge.scan(
                entries, roots: sweep, only: category, progress: progress)
            progress.end()
            let items = found.flatMap(\.items)
            let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "reclaimedBytes": .int(0),
                            "wouldReclaimBytes": .number(total),
                            "items": .int(items.count),
                            "applied": .bool(false),
                        ]))
                    return
                }
                CLIOut.out(
                    "would move \(items.count) items, \(ByteFormatter.string(total)), "
                        + "to the Trash")
                CLIOut.note("pass --yes to do it")
                return
            }
            progress.begin("moving \(items.count) items to the Trash")
            let reclaimed = JunkScanner.clean(items)
            progress.end()
            guard !json else {
                CLIOut.json(
                    .object([
                        "reclaimedBytes": .number(reclaimed),
                        "wouldReclaimBytes": .number(total),
                        "items": .int(items.count),
                        "applied": .bool(true),
                    ]))
                return
            }
            CLIOut.out("moved \(ByteFormatter.string(reclaimed)) to the Trash")
        }
    }
}

struct CleanerDrivesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drives", abstract: "The volumes the cleaner can scan.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let drives = JunkScanner.drives()
            guard !json else {
                CLIOut.json(
                    .array(
                        drives.map { drive in
                            .object([
                                "id": .string(drive.id),
                                "name": .string(drive.name),
                                "totalBytes": .number(drive.totalBytes),
                                "external": .bool(drive.isExternal),
                            ])
                        }))
                return
            }
            let rows = drives.map { drive in
                [
                    drive.name, drive.id, ByteFormatter.string(drive.totalBytes),
                    drive.isExternal ? "external" : "internal",
                ]
            }
            CLIOut.out(TextTable.render(headers: ["NAME", "MOUNT", "SIZE", "KIND"], rows: rows))
        }
    }
}
