import AppKit
import ArgumentParser
import EdithKit
import Foundation

struct ScratchpadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scratchpad",
        abstract: "Named autosaving pads for temporary plain text.",
        subcommands: [
            ScratchpadListCommand.self, ScratchpadShowCommand.self,
            ScratchpadCreateCommand.self, ScratchpadSetCommand.self,
            ScratchpadRenameCommand.self, ScratchpadDuplicateCommand.self,
            ScratchpadRemoveCommand.self, ScratchpadClearCommand.self,
            ScratchpadCopyAllCommand.self, ScratchpadExportCommand.self,
            ScratchpadOpenCommand.self, ScratchpadRememberCommand.self,
        ],
        defaultSubcommand: ScratchpadListCommand.self)
}

enum ScratchpadCLI {
    static var retention: ScratchpadRetention {
        ScratchpadRetention.resolved(
            CLIEnvironment.sharedDefaults.string(forKey: AppStorageKeys.Scratchpad.retention))
    }

    static func load() throws -> ScratchpadDocument {
        try ScratchpadRepository.load(retention: retention)
    }

    static func pad(_ selector: String?, in document: ScratchpadDocument) throws -> ScratchpadPad {
        if let selector { return try ScratchpadRepository.pad(selector, in: document) }
        guard let selected = document.selectedPad else {
            throw CLIFailure.unavailable("there is no selected scratchpad")
        }
        return selected
    }

    static func json(_ pad: ScratchpadPad, selected: Bool) -> JSONValue {
        .object([
            "id": .string(pad.id.uuidString),
            "name": .string(pad.name),
            "text": .string(pad.text),
            "characters": .int(pad.text.count),
            "selected": .bool(selected),
            "createdAt": .date(pad.createdAt),
            "modifiedAt": .date(pad.modifiedAt),
        ])
    }

    static func announce() {
        CLIEnvironment.deliver(IPC.Name.scratchpadChanged, nil)
    }

    static func content(text: String?, file: String?) throws -> String {
        guard text == nil || file == nil else {
            throw CLIFailure("pass either --text or --file, not both")
        }
        if let text { return text }
        if let file {
            let data =
                file == "-"
                ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: file))
            guard let value = String(data: data, encoding: .utf8) else {
                throw CLIFailure("scratchpad input must be UTF-8 text")
            }
            return value
        }
        return ""
    }
}

struct ScratchpadListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List pads in tab order.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Option(help: "Only pads whose name or text contains this query.") var search: String?

    func run() async throws {
        try await execute {
            let document = try ScratchpadCLI.load()
            let results =
                search.map { ScratchpadRepository.search($0, in: document) }
                ?? document.pads.map { ScratchpadSearchResult(pad: $0, matchCount: 0) }
            if json {
                CLIOut.json(
                    .array(
                        results.map { result in
                            guard
                                case var .object(fields) = ScratchpadCLI.json(
                                    result.pad, selected: result.pad.id == document.selectedID)
                            else { return .null }
                            fields["matches"] = .int(result.matchCount)
                            return .object(fields)
                        }))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "CHARS", "MATCHES", "SELECTED", "MODIFIED"],
                    rows: results.map { result in
                        [
                            result.pad.name, String(result.pad.text.count),
                            search == nil ? "" : String(result.matchCount),
                            result.pad.id == document.selectedID ? "yes" : "",
                            result.pad.modifiedAt.map(JSONSerializer.iso.string(from:)) ?? "",
                        ]
                    }))
        }
    }
}

struct ScratchpadShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Print one pad's text.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Pad name or id. Omit for the selected pad.") var pad: String?

    func run() async throws {
        try await execute {
            let document = try ScratchpadCLI.load()
            let value = try ScratchpadCLI.pad(pad, in: document)
            if json {
                CLIOut.json(ScratchpadCLI.json(value, selected: value.id == document.selectedID))
            } else {
                CLIOut.out(value.text)
            }
        }
    }
}

struct ScratchpadCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Create and select a new pad.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Option(help: "Name for the new pad.") var name: String?
    @Option(help: "Initial text.") var text: String?
    @Option(help: "Read initial UTF-8 text from this path, or - for stdin.") var file: String?

    func run() async throws {
        try await execute {
            _ = try ScratchpadCLI.load()
            let body = try ScratchpadCLI.content(text: text, file: file)
            let document = try ScratchpadRepository.create(name: name, text: body)
            let created = try ScratchpadCLI.pad(nil, in: document)
            ScratchpadCLI.announce()
            if json {
                CLIOut.json(ScratchpadCLI.json(created, selected: true))
            } else {
                CLIOut.out("created \(created.name)")
            }
        }
    }
}

struct ScratchpadSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Replace one pad's text.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Option(help: "Replacement text.") var text: String?
    @Option(help: "Read replacement UTF-8 text from this path, or - for stdin.") var file: String?
    @Argument(help: "Pad name or id. Omit for the selected pad.") var pad: String?

    func run() async throws {
        try await execute {
            guard text != nil || file != nil else {
                throw CLIFailure("pass --text or --file")
            }
            let current = try ScratchpadCLI.load()
            let target = try ScratchpadCLI.pad(pad, in: current)
            let body = try ScratchpadCLI.content(text: text, file: file)
            let document = try ScratchpadRepository.update(target.id.uuidString, text: body)
            let updated = try ScratchpadCLI.pad(nil, in: document)
            ScratchpadCLI.announce()
            if json {
                CLIOut.json(ScratchpadCLI.json(updated, selected: true))
            } else {
                CLIOut.out("updated \(updated.name)")
            }
        }
    }
}

struct ScratchpadRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename", abstract: "Rename one pad.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Pad name or id.") var pad: String
    @Argument(help: "New pad name.") var name: String

    func run() async throws {
        try await execute {
            _ = try ScratchpadCLI.load()
            let document = try ScratchpadRepository.rename(pad, to: name)
            let updated = try ScratchpadCLI.pad(nil, in: document)
            ScratchpadCLI.announce()
            if json {
                CLIOut.json(ScratchpadCLI.json(updated, selected: true))
            } else {
                CLIOut.out("renamed to \(updated.name)")
            }
        }
    }
}

struct ScratchpadDuplicateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate", abstract: "Duplicate and select one pad.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Pad name or id. Omit for the selected pad.") var pad: String?

    func run() async throws {
        try await execute {
            let current = try ScratchpadCLI.load()
            let source = try ScratchpadCLI.pad(pad, in: current)
            let document = try ScratchpadRepository.duplicate(source.id.uuidString)
            let copy = try ScratchpadCLI.pad(nil, in: document)
            ScratchpadCLI.announce()
            if json {
                CLIOut.json(ScratchpadCLI.json(copy, selected: true))
            } else {
                CLIOut.out("duplicated as \(copy.name)")
            }
        }
    }
}

struct ScratchpadRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Remove one pad.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Flag(help: "Actually remove it. Without this nothing is touched.") var yes = false
    @Argument(help: "Pad name or id. Omit for the selected pad.") var pad: String?

    func run() async throws {
        try await execute {
            let document = try ScratchpadCLI.load()
            let target = try ScratchpadCLI.pad(pad, in: document)
            let plan = CLIDestructivePlan(
                action: "remove scratchpad", targets: [target.id.uuidString],
                confirmed: yes, json: json, fields: ["name": .string(target.name)])
            guard plan.shouldApply() else { return }
            let updated = try ScratchpadRepository.remove(target.id.uuidString)
            ScratchpadCLI.announce()
            plan.finish(
                changed: true, plain: "removed \(target.name)",
                fields: ["remaining": .int(updated.pads.count)])
        }
    }
}

struct ScratchpadClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Clear one pad's text.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Flag(help: "Actually clear it. Without this nothing is touched.") var yes = false
    @Argument(help: "Pad name or id. Omit for the selected pad.") var pad: String?

    func run() async throws {
        try await execute {
            let document = try ScratchpadCLI.load()
            let target = try ScratchpadCLI.pad(pad, in: document)
            let plan = CLIDestructivePlan(
                action: "clear scratchpad", targets: [target.id.uuidString],
                confirmed: yes, json: json,
                fields: ["name": .string(target.name), "characters": .int(target.text.count)])
            guard plan.shouldApply() else { return }
            _ = try ScratchpadRepository.clear(target.id.uuidString)
            ScratchpadCLI.announce()
            plan.finish(changed: !target.text.isEmpty, plain: "cleared \(target.name)")
        }
    }
}

struct ScratchpadCopyAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-all", abstract: "Copy all text from one pad.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Pad name or id. Omit for the selected pad.") var pad: String?

    func run() async throws {
        try await execute {
            let document = try ScratchpadCLI.load()
            let target = try ScratchpadCLI.pad(pad, in: document)
            let text = try ScratchpadRepository.copyAllText(target)
            CLIEnvironment.clipboardPasteboard.clearContents()
            CLIEnvironment.clipboardPasteboard.setString(text, forType: .string)
            if json {
                CLIOut.json(
                    .object([
                        "id": .string(target.id.uuidString), "name": .string(target.name),
                        "characters": .int(text.count), "copied": .bool(true),
                    ]))
            } else {
                CLIOut.out("copied \(target.name)")
            }
        }
    }
}

struct ScratchpadExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export one pad as exact UTF-8 text.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Pad name or id.") var pad: String
    @Argument(help: "Destination text or Markdown file.", completion: .file()) var path: String

    func run() async throws {
        try await execute {
            let document = try ScratchpadCLI.load()
            let target = try ScratchpadCLI.pad(pad, in: document)
            let destination = URL(fileURLWithPath: path).standardizedFileURL
            try ScratchpadRepository.export(target, to: destination)
            if json {
                CLIOut.json(
                    .object([
                        "id": .string(target.id.uuidString), "name": .string(target.name),
                        "path": .string(destination.path), "characters": .int(target.text.count),
                    ]))
            } else {
                CLIOut.out(destination.path)
            }
        }
    }
}

struct ScratchpadOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open or close the Scratchpad panel.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            guard CLIEnvironment.sharedDefaults.bool(forKey: AppStorageKeys.Scratchpad.enabled)
            else {
                throw CLIFailure.unavailable(
                    "the Scratchpad extension is off",
                    hint: "run `ed extensions enable scratchpad`")
            }
            guard CLIEnvironment.isHelperRunning() else {
                throw CLIFailure.unavailable("Edith's menu bar helper is not running")
            }
            CLIEnvironment.deliver(IPC.Name.requestScratchpadPanel, nil)
            if json {
                CLIOut.json(.object(["requested": .bool(true)]))
            } else {
                CLIOut.out("toggled Scratchpad")
            }
        }
    }
}

struct ScratchpadRememberCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remember", abstract: "Promote one pad into Companion memory.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Pad name or id. Omit for the selected pad.") var pad: String?

    func run() async throws {
        try await execute {
            guard CLIEnvironment.sharedDefaults.bool(forKey: AppStorageKeys.Tabs.companionEnabled)
            else {
                throw CLIFailure.unavailable(
                    "the Companion extension is off",
                    hint:
                        "Scratchpad works without Companion; enable Companion before promoting a pad"
                )
            }
            let document = try ScratchpadCLI.load()
            let target = try ScratchpadCLI.pad(pad, in: document)
            guard !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure.unavailable("the scratchpad is empty")
            }
            let body = "# \(target.name)\n\n\(target.text)"
            let mtime = ISO8601DateFormatter().string(from: target.modifiedAt ?? Date())
            let outcomes = try await CompanionClient(
                baseURL: CLIEnvironment.resolvedCompanionEndpoint(nil)
            ).ingest(files: [
                CompanionIngestFile(
                    name: "scratchpad-\(target.id.uuidString.lowercased()).md", text: body,
                    mtime: mtime)
            ])
            let outcome = outcomes.first
            if json {
                CLIOut.json(
                    .object([
                        "id": .string(target.id.uuidString), "name": .string(target.name),
                        "status": .optional(outcome?.status),
                        "episodeId": .optional(outcome?.episodeId),
                    ]))
            } else {
                CLIOut.out(
                    outcome?.status == "ingested"
                        ? "remembered \(target.name)" : "already remembered \(target.name)")
            }
        }
    }
}
