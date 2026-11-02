import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct CleanerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleaner",
        abstract: "Scan and trash the developer caches the disk cleaner can reclaim.",
        discussion: """
            Scanning walks your home directory, so it runs in this process and needs no
            app. `ed cleaner clean` moves what it finds to the Trash, never deleting in
            place, and refuses to run without --yes so a stray tab cannot cost you a
            build cache.

            Reads cache folders. scan does not change disk. clean changes disk by moving files to the Trash only after --yes.

            ed cleaner scan
            ed cleaner worktrees --root ~/code --older-than 1w
            ed cleaner clean --yes
            """,
        subcommands: [
            CleanerScanCommand.self, CleanerCategoriesCommand.self, CleanerCleanCommand.self,
            CleanerWorktreesCommand.self, CleanerDrivesCommand.self,
        ],
        defaultSubcommand: CleanerScanCommand.self)
}

@MainActor enum CleanerBridge {
    static var home: URL { CleanerCLIEnvironment.home }

    static var projectCategoryIDs: [String] { ProjectRules.categoryIDs + [Worktrees.categoryID] }

    static func filters(olderThan: String?, includeDirty: Bool) throws -> CleanerFilters {
        guard let olderThan else { return CleanerFilters(protectDirty: !includeDirty) }
        guard let seconds = CleanerAge.parse(olderThan) else {
            throw CLIFailure(
                "\(olderThan) is not a duration",
                hint: "use a number and a unit: 30m, 6h, 2d, 1w, 3mo")
        }
        return CleanerFilters(minimumAge: seconds, protectDirty: !includeDirty)
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
            let expanded = try ExtensionCLIContext.resolvePath(
                (path as NSString).expandingTildeInPath
            ).path
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
        filters: CleanerFilters = CleanerFilters(protectDirty: false),
        progress: CleanerCLIProgress? = nil
    ) async throws
        -> [JunkCategory]
    {
        let token = Progress(totalUnitCount: 0)
        let home = CleanerCLIEnvironment.home
        return try await withTaskCancellationHandler {
            let result = try await BlockingWork.perform {
                CleanerOperationExecution.scan(
                    entries: entries, roots: roots, only: only, filters: filters, home: home,
                    isCancelled: { token.isCancelled }, progress: { progress?.update($0) })
            }
            try Task.checkCancellation()
            return result.categories
        } onCancel: {
            token.cancel()
        }
    }

    static func json(_ category: JunkCategory) -> JSONValue {
        .object([
            "category": .string(category.id),
            "name": .string(category.name),
            "detail": .string(category.detail),
            "sizeBytes": .number(category.sizeBytes),
            "items": .array(
                category.items.map(json)),
        ])
    }
}

extension CleanerBridge {
    static func json(_ item: JunkItem) -> JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(item.name),
            "path": .string(item.path.path),
            "sizeBytes": .number(item.sizeBytes),
        ]
        if let modified = item.lastModified {
            fields["lastModified"] = .string(ISO8601DateFormatter().string(from: modified))
        }
        if let worktree = item.worktree {
            var info: [String: JSONValue] = [
                "locked": .bool(worktree.locked), "upstreamGone": .bool(worktree.upstreamGone),
                "merged": .bool(worktree.merged),
            ]
            if let branch = worktree.branch { info["branch"] = .string(branch) }
            if let repository = worktree.repository { info["repository"] = .string(repository) }
            if let dirty = worktree.dirty { info["dirty"] = .bool(dirty) }
            if let unpushed = worktree.unpushed { info["unpushed"] = .int(unpushed) }
            fields["worktree"] = .object(info)
        }
        return .object(fields)
    }

    static func worktreeState(_ info: WorktreeInfo) -> String {
        var states: [String] = []
        if info.dirty == true { states.append("uncommitted") }
        if let unpushed = info.unpushed, unpushed > 0 { states.append("\(unpushed) unpushed") }
        if info.merged {
            states.append("merged")
        } else if info.upstreamGone {
            states.append("upstream gone")
        }
        if info.locked { states.append("locked") }
        return states.isEmpty ? "clean" : states.joined(separator: ", ")
    }
}

struct CleanerCategoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "categories",
        abstract: "List the cache categories the cleaner knows how to reclaim.",
        discussion: """
            List the cache categories the cleaner knows how to reclaim.
            Reads the built-in category list. Does not change disk.

            ed cleaner categories
            ed cleaner categories --json
            """,
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
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
        commandName: "scan", abstract: "Measure what could be reclaimed.",
        discussion: """
            Measure developer caches that could be reclaimed.
            Reads the home directory, or --root. Does not change files. Does not delete anything.

            ed cleaner scan
            ed cleaner scan --root ~/Library --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only this category.")
    var category: String?

    @Option(
        name: .customLong("root"),
        help: "Also sweep this folder for project junk. Repeat for more than one.")
    var roots: [String] = []

    @Option(
        name: .customLong("older-than"),
        help: "Only project items untouched for this long, such as 6h, 2d, 1w or 3mo.")
    var olderThan: String?

    @MainActor func run() async throws {
        try await execute {
            let sweep = try CleanerBridge.roots(roots)
            let filters = try CleanerBridge.filters(olderThan: olderThan, includeDirty: true)
            let entries =
                sweep.isEmpty || category == nil
                ? try CleanerBridge.categories(only: category)
                : ((try? CleanerBridge.categories(only: category)) ?? [])
            let progress = CleanerCLIProgress(json: json)
            progress.begin("scanning"); defer { progress.end() }
            let found = try await CleanerBridge.scan(
                entries, roots: sweep, only: category, filters: filters, progress: progress)
            progress.end()
            let total = JunkScanner.uniqueBytes(found.flatMap(\.items))
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
                    category.id, CleanerByteFormat.string(category.sizeBytes),
                    String(category.items.count), category.name,
                ]
            }
            CLIOut.out(TextTable.render(headers: ["ID", "SIZE", "ITEMS", "NAME"], rows: rows))
            CLIOut.out("")
            CLIOut.out("total \(CleanerByteFormat.string(total))")
        }
    }
}

struct CleanerCleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean", abstract: "Move the scanned caches to the Trash.",
        discussion: """
            Move scanned caches to the Trash.
            Reads the last scan. Without --yes, prints the plan and does not change anything. With --yes, changes disk by moving files to the Trash, never deleting in place.

            Removing a worktree moves its folder to the Trash and prunes it from the repository.
            The branch and its commits stay. Worktrees with uncommitted changes are skipped unless
            --include-dirty is passed.

            ed cleaner clean
            ed cleaner clean --category xcode --yes
            ed cleaner clean --root ~/code --category worktrees --older-than 2w --yes
            """)

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

    @Option(
        name: .customLong("older-than"),
        help: "Only project items untouched for this long, such as 6h, 2d, 1w or 3mo.")
    var olderThan: String?

    @Flag(
        name: .customLong("include-dirty"),
        help: "Also clean worktrees that have uncommitted changes.")
    var includeDirty = false

    @MainActor func run() async throws {
        try await execute {
            let sweep = try CleanerBridge.roots(roots)
            let filters = try CleanerBridge.filters(
                olderThan: olderThan, includeDirty: includeDirty)
            let entries =
                sweep.isEmpty || category == nil
                ? try CleanerBridge.categories(only: category)
                : ((try? CleanerBridge.categories(only: category)) ?? [])
            let progress = CleanerCLIProgress(json: json)
            progress.begin("scanning"); defer { progress.end() }
            let found = try await CleanerBridge.scan(
                entries, roots: sweep, only: category, filters: filters, progress: progress)
            progress.end()
            let items = JunkScanner.outermost(found.flatMap(\.items))
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
                    "would move \(items.count) items, \(CleanerByteFormat.string(total)), "
                        + "to the Trash")
                CLIOut.note("pass --yes to do it")
                return
            }
            progress.begin("moving \(items.count) items to the Trash")
            let result = try await CleanerCLIEnvironment.clean(items)
            progress.end()
            guard !json else {
                CLIOut.json(
                    .object([
                        "reclaimedBytes": .number(result.reclaimedBytes),
                        "wouldReclaimBytes": .number(total),
                        "items": .int(items.count),
                        "applied": .bool(true),
                    ]))
                return
            }
            CLIOut.out("moved \(CleanerByteFormat.string(result.reclaimedBytes)) to the Trash")
        }
    }
}

struct CleanerWorktreesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktrees", abstract: "List linked git worktrees under a folder.",
        discussion: """
            List linked git worktrees with their branch, size, last edit and git state.
            Reads the folders passed with --root and runs read-only git status. Does not change disk.

            ed cleaner worktrees --root ~/code
            ed cleaner worktrees --root ~/code --older-than 1w --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .customLong("root"), help: "Folder to search. Repeat for more than one.")
    var roots: [String] = []

    @Option(
        name: .customLong("older-than"),
        help: "Only worktrees untouched for this long, such as 6h, 2d, 1w or 3mo.")
    var olderThan: String?

    @MainActor func run() async throws {
        try await execute {
            let sweep = try CleanerBridge.roots(roots)
            guard !sweep.isEmpty else {
                throw CLIFailure(
                    "pass a folder to search", hint: "ed cleaner worktrees --root ~/code")
            }
            let filters = try CleanerBridge.filters(olderThan: olderThan, includeDirty: true)
            let progress = CleanerCLIProgress(json: json)
            progress.begin("scanning"); defer { progress.end() }
            let items =
                try await CleanerBridge.scan(
                    [], roots: sweep, only: Worktrees.categoryID, filters: filters,
                    progress: progress
                ).flatMap(\.items)
            progress.end()
            guard !json else {
                CLIOut.json(.array(items.map(CleanerBridge.json)))
                return
            }
            guard !items.isEmpty else {
                CLIOut.note("no linked worktrees found")
                return
            }
            let now = Date()
            let rows = items.map { item in
                [
                    item.worktree?.branch ?? "(detached)",
                    CleanerByteFormat.string(item.sizeBytes),
                    CleanerAgeText.since(item.lastModified, now: now) ?? "",
                    item.worktree.map(CleanerBridge.worktreeState) ?? "",
                    item.name,
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["BRANCH", "SIZE", "EDITED", "STATE", "PATH"], rows: rows))
        }
    }
}

struct CleanerDrivesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drives", abstract: "List the volumes the cleaner can scan.",
        discussion: """
            List the volumes the cleaner can scan.
            Reads mounted volumes. Does not change them.

            ed cleaner drives
            ed cleaner drives --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let drives = CleanerCLIEnvironment.drives()
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
                    drive.name, drive.id, CleanerByteFormat.string(drive.totalBytes),
                    drive.isExternal ? "external" : "internal",
                ]
            }
            CLIOut.out(TextTable.render(headers: ["NAME", "MOUNT", "SIZE", "KIND"], rows: rows))
        }
    }
}

enum CleanerByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(value)) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
