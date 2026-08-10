import ArgumentParser
import EdithKit
import Foundation

struct ShelfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shelf",
        abstract: "The files parked on the notch shelf.",
        discussion: """
            The shelf is a folder plus an index on disk, so these commands work whether
            or not the app is running. Items are numbered from 1, newest first.
            """,
        subcommands: [
            ShelfListCommand.self, ShelfPathCommand.self, ShelfAddCommand.self,
            ShelfRemoveCommand.self, ShelfClearCommand.self,
        ],
        defaultSubcommand: ShelfListCommand.self)
}

enum ShelfBridge {
    static func items() -> [ShelfItem] {
        ShelfIndex.load().sorted { $0.addedAt > $1.addedAt }
    }

    static func announce() {
        AppBridge.post(IPC.Name.shelfChanged, userInfo: ["sender": "ed"])
    }

    static func item(at index: Int) throws -> (item: ShelfItem, all: [ShelfItem]) {
        let all = items()
        guard !all.isEmpty else {
            throw CLIFailure.unavailable(
                "the shelf is empty",
                hint: "drag something onto the notch, or run `ed shelf add <file>`")
        }
        guard index >= 1, index <= all.count else {
            throw CLIFailure.notFound(
                "there is no shelf item \(index)",
                hint: "the shelf holds \(all.count) items, numbered from 1")
        }
        return (all[index - 1], all)
    }

    static func json(_ item: ShelfItem, index: Int) -> JSONValue {
        let url = ShelfIndex.fileURL(for: item)
        let size =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        return .object([
            "index": .int(index),
            "id": .string(item.id.uuidString),
            "name": .string(item.name),
            "path": .string(url.path),
            "sizeBytes": .int(size),
            "addedAt": .date(item.addedAt),
            "exists": .bool(FileManager.default.fileExists(atPath: url.path)),
        ])
    }

    static func uniqueName(_ proposed: String) -> String {
        var name = proposed
        var counter = 2
        let base = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        while FileManager.default.fileExists(
            atPath: ShelfIndex.root.appendingPathComponent(name).path)
        {
            name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return name
    }
}

struct ShelfListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List what is on the shelf.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let items = ShelfBridge.items()
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
                let url = ShelfIndex.fileURL(for: item)
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
        commandName: "path", abstract: "Print the path of one shelf item.")

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
            CLIOut.out(ShelfIndex.fileURL(for: found.item).path)
        }
    }
}

struct ShelfAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Copy a file onto the shelf.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The file to park.")
    var file: String

    func run() async throws {
        try await execute {
            let source = URL(fileURLWithPath: file.expandingTilde())
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CLIFailure.notFound("no file at \(source.path)")
            }
            let name = ShelfBridge.uniqueName(source.lastPathComponent)
            try? FileManager.default.createDirectory(
                at: ShelfIndex.root, withIntermediateDirectories: true)
            do {
                try FileManager.default.copyItem(
                    at: source, to: ShelfIndex.root.appendingPathComponent(name))
            } catch {
                throw CLIFailure(
                    "could not put \(source.lastPathComponent) on the shelf",
                    hint: error.localizedDescription)
            }
            let item = ShelfItem(id: UUID(), name: name, addedAt: Date())
            ShelfIndex.save(ShelfIndex.load() + [item])
            ShelfBridge.announce()
            guard !json else {
                CLIOut.json(ShelfBridge.json(item, index: 1))
                return
            }
            CLIOut.out("shelved \(name)")
        }
    }
}

struct ShelfRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Take one item off the shelf.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The item number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try ShelfBridge.item(at: index)
            try? FileManager.default.removeItem(at: ShelfIndex.fileURL(for: found.item))
            let kept = found.all.filter { $0.id != found.item.id }
            ShelfIndex.save(kept)
            ShelfBridge.announce()
            guard !json else {
                CLIOut.json(.object(["removed": .int(index), "remaining": .int(kept.count)]))
                return
            }
            CLIOut.out("removed \(found.item.name), \(kept.count) left")
        }
    }
}

struct ShelfClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Empty the shelf.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let all = ShelfBridge.items()
            for item in all {
                try? FileManager.default.removeItem(at: ShelfIndex.fileURL(for: item))
            }
            ShelfIndex.save([])
            ShelfBridge.announce()
            guard !json else {
                CLIOut.json(.object(["removed": .int(all.count)]))
                return
            }
            CLIOut.out("cleared \(all.count) items")
        }
    }
}
