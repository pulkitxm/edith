import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct ShelfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shelf",
        abstract: "List, add, and remove files parked on the notch shelf.",
        discussion: """
            The extension owns the shelf folder and index on disk. Commands run through
            its engine while the extension is enabled. Items are numbered from 1, newest first.

            Reads the shelf folder and index. add and update change items. rm, clear, and purge change the shelf only after --yes. ls and path do not change anything.

            ed shelf ls
            ed shelf add ./report.pdf
            """,
        subcommands: [
            ShelfListCommand.self, ShelfPathCommand.self, ShelfAddCommand.self,
            ShelfAddTextCommand.self, ShelfUpdateCommand.self, ShelfRemoveCommand.self,
            ShelfClearCommand.self, ShelfPurgeCommand.self, ShelfOpenCommand.self,
            ShelfRevealCommand.self, ShelfShareCommand.self,
        ],
        defaultSubcommand: ShelfListCommand.self)
}

enum ShelfActionBridge {
    static func run(_ operation: ShelfItemOperation, indices: [Int], json: Bool) async throws {
        let selected: [(index: Int, item: ShelfItem)]
        if operation == .share {
            selected = try ShelfBridge.selection(at: indices)
            try await ShelfCLIEnvironment.share(selected.map(\.item.id))
        } else {
            let action = try ShelfBridge.pinnedSelection(at: indices)
            selected = action.selected
            let urls: [URL]
            do {
                urls = try action.snapshot.fileURLs(for: selected.map(\.item.id))
            } catch {
                throw ShelfBridge.failure(error, action: "read the selected shelf items")
            }
            guard
                await ShelfItemOperationExecution.perform(
                    operation, urls: urls, open: ShelfCLIEnvironment.open,
                    reveal: ShelfCLIEnvironment.reveal)
            else {
                throw CLIFailure.unavailable(
                    "macOS could not \(operation.rawValue) the shelf items")
            }
            withExtendedLifetime(action.snapshot) {}
        }
        guard !json else {
            let status = operation == .reveal ? "requested" : "opened"
            CLIOut.json(
                .object([
                    "action": .string(operation.rawValue),
                    "items": .array(
                        selected.map { ShelfBridge.json($0.item, index: $0.index) }),
                    status: .bool(true),
                ]))
            return
        }
        let names = selected.map(\.item.name).joined(separator: ", ")
        let verb =
            operation == .share
            ? "opened sharing for"
            : operation == .reveal ? "requested reveal for" : "opened"
        CLIOut.out("\(verb) \(names)")
    }
}

struct ShelfOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open selected shelf items.",
        discussion: """
            Open selected shelf items in their default apps.
            Reads those shelf rows. Does not change the shelf. Opens the files.

            ed shelf open 1
            ed shelf open 1 --json
            """)
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Item numbers, counting from 1.") var indices: [Int] = []
    func run() async throws {
        try await execute { try await ShelfActionBridge.run(.open, indices: indices, json: json) }
    }
}

struct ShelfRevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal", abstract: "Reveal selected shelf items in Finder.",
        discussion: """
            Reveal selected shelf items in Finder.
            Reads those shelf rows. Does not change the shelf. Changes Finder focus.

            ed shelf reveal 1
            ed shelf reveal 1 --json
            """)
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Item numbers, counting from 1.") var indices: [Int] = []
    func run() async throws {
        try await execute { try await ShelfActionBridge.run(.reveal, indices: indices, json: json) }
    }
}

struct ShelfShareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share", abstract: "Open sharing for selected shelf items.",
        discussion: """
            Open the share sheet for selected shelf items.
            Reads those shelf rows. Does not change the shelf. Opens the share UI.

            ed shelf share 1
            ed shelf share 1 --json
            """)
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Item numbers, counting from 1.") var indices: [Int] = []
    func run() async throws {
        try await execute { try await ShelfActionBridge.run(.share, indices: indices, json: json) }
    }
}

enum ShelfBridge {
    static func items() throws -> [ShelfItem] {
        do {
            return try ShelfMutationExecution.snapshot(root: ShelfCLIEnvironment.root).items.sorted
            { $0.addedAt > $1.addedAt }
        } catch {
            throw failure(error, action: "read the shelf")
        }
    }

    static func item(at index: Int) throws -> (item: ShelfItem, all: [ShelfItem]) {
        let all = try items()
        let selected = try selection(at: [index], in: all)
        return (selected[0].item, all)
    }

    static func selection(at indices: [Int]) throws -> [(index: Int, item: ShelfItem)] {
        let all = try items()
        return try selection(at: indices, in: all)
    }

    static func pinnedSelection(at indices: [Int]) throws -> (
        snapshot: ShelfPinnedSelection, selected: [(index: Int, item: ShelfItem)]
    ) {
        let snapshot: ShelfPinnedSelection
        do {
            snapshot = try ShelfMutationExecution.pinnedSelection(root: ShelfCLIEnvironment.root)
        } catch {
            throw failure(error, action: "read the shelf")
        }
        let all = snapshot.items.sorted { $0.addedAt > $1.addedAt }
        return (snapshot, try selection(at: indices, in: all))
    }

    private static func selection(
        at indices: [Int], in all: [ShelfItem]
    ) throws -> [(index: Int, item: ShelfItem)] {
        guard !indices.isEmpty else {
            throw CLIFailure.usage("at least one item number is required")
        }
        guard !all.isEmpty else {
            throw CLIFailure.unavailable(
                "the shelf is empty",
                hint: "drag something onto the notch, or run `ed shelf add <file>`")
        }
        var seen = Set<Int>()
        var selected: [(index: Int, item: ShelfItem)] = []
        for index in indices where seen.insert(index).inserted {
            guard index >= 1, index <= all.count else {
                throw CLIFailure.notFound(
                    "there is no shelf item \(index)",
                    hint: "the shelf holds \(all.count) items, numbered from 1")
            }
            selected.append((index, all[index - 1]))
        }
        return selected
    }

    static func json(_ item: ShelfItem, index: Int) -> JSONValue {
        let url = ShelfCLIEnvironment.root.appendingPathComponent(item.name)
        let size =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        let position: JSONValue =
            item.position.map {
                .object(["x": .double(Double($0.x)), "y": .double(Double($0.y))])
            } ?? .null
        return .object([
            "index": .int(index),
            "id": .string(item.id.uuidString),
            "name": .string(item.name),
            "path": .string(url.path),
            "sizeBytes": .int(size),
            "addedAt": .date(item.addedAt),
            "exists": .bool(FileManager.default.fileExists(atPath: url.path)),
            "position": position,
        ])
    }

    static func index(of item: ShelfItem, in items: [ShelfItem]) -> Int? {
        items.sorted { $0.addedAt > $1.addedAt }
            .firstIndex { $0.id == item.id }
            .map { $0 + 1 }
    }

    static func update(
        at index: Int, position: CGPoint, beforeApply: () throws -> Void = {}
    ) throws -> (item: ShelfItem, index: Int, changed: Bool) {
        let found = try item(at: index)
        try beforeApply()
        let result: ShelfPositionUpdateResult
        do {
            result = try ShelfMutationExecution.updatePositions(
                [found.item.id: position], root: ShelfCLIEnvironment.root, sender: "ed")
        } catch {
            throw failure(error, action: "update \(found.item.name)")
        }
        guard let item = result.items.first(where: { $0.id == found.item.id }) else {
            throw CLIFailure("could not update \(found.item.name)")
        }
        guard let finalIndex = Self.index(of: item, in: result.items) else {
            throw CLIFailure("could not find \(item.name) on the shelf")
        }
        return (item, finalIndex, result.changed)
    }

    static func failure(_ error: Error, action: String) -> CLIFailure {
        if case ShelfMutationError.sourceMissing(let path) = error {
            return CLIFailure.notFound("no file at \(path)")
        }
        return CLIFailure("could not \(action)", hint: error.localizedDescription)
    }
}

struct ShelfListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List what is on the shelf.",
        discussion: """
            List files parked on the notch shelf, newest first.
            Reads the shelf index. Does not change it. Numbers start at 1.

            ed shelf ls
            ed shelf ls --json
            """, aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let items = try ShelfBridge.items()
            guard !json else {
                CLIOut.json(
                    .array(items.enumerated().map { ShelfBridge.json($1, index: $0 + 1) }))
                return
            }
            guard !items.isEmpty else {
                CLIOut.note("the shelf is empty")
                return
            }
            let rows = items.enumerated().map { offset, item in
                let url = ShelfCLIEnvironment.root.appendingPathComponent(item.name)
                let size =
                    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                    as? Int ?? 0
                return [
                    String(offset + 1), item.name, ByteFormatter.string(Int64(size)),
                    JSONSerializer.iso.string(from: item.addedAt),
                ]
            }
            CLIOut.out(TextTable.render(headers: ["#", "NAME", "SIZE", "ADDED"], rows: rows))
        }
    }
}

struct ShelfPathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path", abstract: "Print the path of one shelf item.",
        discussion: """
            Print the on-disk path of one shelf item.
            Reads the shelf index. Does not change the item.

            ed shelf path 1
            ed shelf path 1 --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The item number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try ShelfBridge.item(at: index)
            guard !json else {
                CLIOut.json(ShelfBridge.json(found.item, index: index))
                return
            }
            CLIOut.out(ShelfCLIEnvironment.root.appendingPathComponent(found.item.name).path)
        }
    }
}

struct ShelfAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Copy a file onto the shelf.",
        discussion: """
            Copy a file onto the shelf.
            Reads the source file. Changes the shelf by adding a copy.

            ed shelf add ./report.pdf
            ed shelf add ./report.pdf --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The file to park.")
    var file: String

    func run() async throws {
        try await execute {
            let source = try ExtensionCLIContext.resolvePath(file)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CLIFailure.notFound("no file at \(source.path)")
            }
            let result: ShelfMutationResult
            do {
                result = try ShelfMutationExecution.addCopy(
                    of: source, root: ShelfCLIEnvironment.root, sender: "ed")
            } catch {
                throw ShelfBridge.failure(
                    error, action: "put \(source.lastPathComponent) on the shelf")
            }
            guard let item = result.item else {
                throw CLIFailure("could not put \(source.lastPathComponent) on the shelf")
            }
            guard !json else {
                guard let index = ShelfBridge.index(of: item, in: result.items) else {
                    throw CLIFailure("could not find \(item.name) on the shelf")
                }
                CLIOut.json(ShelfBridge.json(item, index: index))
                return
            }
            CLIOut.out("shelved \(item.name)")
        }
    }
}

struct ShelfAddTextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-text", abstract: "Store a typed snippet on the notch shelf.",
        discussion: """
            Store a text snippet on the shelf.
            Reads the text argument. Changes the shelf by adding an item.

            ed shelf add-text "ship notes"
            ed shelf add-text "ship notes" --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(parsing: .remaining, help: "The text to park.")
    var words: [String] = []

    func run() async throws {
        try await execute {
            let text = words.joined(separator: " ")
            guard !text.isEmpty else { throw CLIFailure.usage("text is required") }
            let result: ShelfMutationResult
            do {
                result = try ShelfMutationExecution.addText(
                    text, root: ShelfCLIEnvironment.root, sender: "ed")
            } catch {
                throw ShelfBridge.failure(error, action: "put text on the shelf")
            }
            guard let item = result.item else {
                throw CLIFailure("could not put text on the shelf")
            }
            guard !json else {
                guard let index = ShelfBridge.index(of: item, in: result.items) else {
                    throw CLIFailure("could not find \(item.name) on the shelf")
                }
                CLIOut.json(ShelfBridge.json(item, index: index))
                return
            }
            CLIOut.out("shelved \(item.name)")
        }
    }
}

struct ShelfUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update one shelf item's canvas position.",
        discussion: """
            Move one shelf item on the notch canvas.
            Reads the item number. Changes that item's stored position.

            ed shelf update 1 --x 0.2 --y 0.4
            ed shelf update 1 --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "The horizontal canvas coordinate.")
    var x: Double

    @Option(name: .long, help: "The vertical canvas coordinate.")
    var y: Double

    @Argument(help: "The item number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
            let result = try ShelfBridge.update(at: index, position: position)
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("update"), "changed": .bool(result.changed),
                        "item": ShelfBridge.json(result.item, index: result.index),
                    ]))
                return
            }
            if result.changed {
                CLIOut.out("moved \(result.item.name) to \(x), \(y)")
            } else {
                CLIOut.note("\(result.item.name) is already at \(x), \(y)")
            }
        }
    }
}

struct ShelfRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Take selected items off the shelf.",
        discussion: """
            Remove selected shelf items.
            Reads the item numbers. Without --yes, does not change anything. With --yes, changes the shelf by removing them.

            ed shelf rm 1
            ed shelf rm 1 --yes
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove it. Without this nothing is touched.")
    var yes = false

    @Argument(help: "Item numbers, counting from 1.")
    var indices: [Int] = []

    func run() async throws {
        try await execute {
            let selected = try ShelfBridge.selection(at: indices)
            let plan = CLIDestructivePlan(
                action: selected.count == 1 ? "remove shelf item" : "remove shelf items",
                targets: selected.map {
                    ShelfCLIEnvironment.root.appendingPathComponent($0.item.name).path
                }, confirmed: yes,
                json: json,
                fields: [
                    "items": .array(
                        selected.map { ShelfBridge.json($0.item, index: $0.index) }),
                    "removed": .int(selected.count),
                ])
            guard plan.shouldApply() else { return }
            let result: ShelfMutationResult
            do {
                result = try ShelfMutationExecution.remove(
                    ids: Set(selected.map(\.item.id)), root: ShelfCLIEnvironment.root, sender: "ed")
            } catch {
                throw ShelfBridge.failure(error, action: "remove shelf items")
            }
            plan.finish(
                changed: true,
                plain: "removed \(result.removed.count) items, \(result.items.count) left",
                fields: ["remaining": .int(result.items.count)])
        }
    }
}

struct ShelfClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Empty the shelf.",
        discussion: """
            Remove every shelf item.
            Reads the index. Without --yes, does not change anything. With --yes, changes the shelf by clearing it.

            ed shelf clear
            ed shelf clear --yes
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually empty it. Without this nothing is touched.")
    var yes = false

    func run() async throws {
        try await execute {
            let all = try ShelfBridge.items()
            let plan = CLIDestructivePlan(
                action: "clear shelf",
                targets: all.map { ShelfCLIEnvironment.root.appendingPathComponent($0.name).path },
                confirmed: yes, json: json, fields: ["removed": .int(all.count)])
            guard plan.shouldApply() else { return }
            let result: ShelfMutationResult
            do {
                result = try ShelfMutationExecution.remove(
                    ids: Set(all.map(\.id)), root: ShelfCLIEnvironment.root, sender: "ed")
            } catch {
                throw ShelfBridge.failure(error, action: "clear the shelf")
            }
            plan.finish(
                changed: !result.removed.isEmpty,
                plain: "cleared \(result.removed.count) items",
                fields: ["remaining": .int(result.items.count)])
        }
    }
}

struct ShelfPurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge", abstract: "Remove shelf items past an expiry window.",
        discussion: """
            Remove shelf items older than the expiry window.
            Reads item ages. Without --yes, prints the plan and does not change anything. With --yes, changes the shelf.

            ed shelf purge
            ed shelf purge --yes
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove expired items. Without this nothing is touched.")
    var yes = false

    @Argument(help: "The expiry window. Defaults to the configured shelf window.")
    var keep: String?

    func run() async throws {
        try await execute {
            let stored = ShelfCLIEnvironment.defaults?.string(
                forKey: AppStorageKeys.Notch.shelfKeepDuration)
            let raw = keep ?? stored ?? ShelfKeepDuration.forever.rawValue
            guard let duration = ShelfKeepDuration(rawValue: raw) else {
                let choices = ShelfKeepDuration.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIFailure.usage(
                    "keep must be \(choices)")
            }
            let expired = try ShelfBridge.items().filter {
                ShelfExpiry.isExpired(addedAt: $0.addedAt, keep: duration)
            }
            let plan = CLIDestructivePlan(
                action: "purge expired shelf items",
                targets: expired.map {
                    ShelfCLIEnvironment.root.appendingPathComponent($0.name).path
                }, confirmed: yes,
                json: json,
                fields: ["keep": .string(duration.rawValue), "removed": .int(expired.count)])
            guard plan.shouldApply() else { return }
            let result: ShelfMutationResult
            do {
                result = try ShelfMutationExecution.remove(
                    ids: Set(expired.map(\.id)), root: ShelfCLIEnvironment.root, sender: "ed")
            } catch {
                throw ShelfBridge.failure(error, action: "purge expired shelf items")
            }
            plan.finish(
                changed: !result.removed.isEmpty,
                plain: "purged \(result.removed.count) expired items",
                fields: ["remaining": .int(result.items.count)])
        }
    }
}
