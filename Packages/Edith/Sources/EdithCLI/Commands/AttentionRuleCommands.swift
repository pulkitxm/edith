import ArgumentParser
import EdithKit
import Foundation

struct AttentionRuleDocument: Codable {
    var categories: [AttentionCategory]
    var rules: [AttentionIdentityRule]

    func applying(to original: AttentionSettings) throws -> AttentionSettings {
        var settings = original
        guard Set(categories.map(\.id)).count == categories.count,
            Set(rules.map(\.id)).count == rules.count
        else { throw CLIFailure.usage("Category and rule IDs must be unique") }
        for category in categories {
            guard !category.id.isEmpty, !category.name.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw CLIFailure.usage("Categories need an ID and a name") }
            if let index = settings.categories.firstIndex(where: { $0.id == category.id }) {
                settings.categories[index] = category
            } else {
                settings.categories.append(category)
            }
        }
        for rule in rules {
            guard !rule.id.isEmpty, !rule.name.trimmingCharacters(in: .whitespaces).isEmpty,
                !rule.isEmpty, settings.categories.contains(where: { $0.id == rule.categoryID })
            else {
                throw CLIFailure.usage("Rules need an ID, name, known category and match criteria")
            }
            if let index = settings.rules.firstIndex(where: { $0.id == rule.id }) {
                settings.rules[index] = rule
            } else {
                settings.rules.append(rule)
            }
        }
        return settings
    }
}

struct AttentionRulesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules", abstract: "Export and import configurable attention rules.",
        discussion: """
            Reads configured categories and matching rules for export, or changes them \
            by importing a validated JSON document. Rules can match URLs, applications, \
            browser profiles, titles and content identities.

            ed attention rules export > rules.json
            ed attention rules import rules.json --dry-run
            """,
        subcommands: [AttentionRulesExportCommand.self, AttentionRulesImportCommand.self],
        defaultSubcommand: AttentionRulesExportCommand.self)
}

struct AttentionRulesExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export categories and complete rules as JSON.",
        discussion: """
            Reads all configured attention categories and rules and prints their JSON \
            document to stdout. It does not change settings or recorded activity. Save \
            the document to edit or transfer the classification configuration.

            ed attention rules export > rules.json
            """)

    func run() async throws {
        try await execute {
            let settings = AttentionCLI.repository.loadSettings()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                AttentionRuleDocument(categories: settings.categories, rules: settings.rules))
            CLIOut.out(String(decoding: data, as: UTF8.self))
        }
    }
}

struct AttentionRulesImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Validate and merge a JSON rule document by ID.",
        discussion: """
            Reads a JSON document containing categories and rules, validates its IDs \
            and category references, then changes settings by merging entries with \
            matching IDs. Existing entries absent from the document remain configured. \
            Use --dry-run to validate without saving changes.

            ed attention rules import rules.json --dry-run --json
            ed attention rules import rules.json --json
            """)
    @Argument(help: "JSON file containing categories and rules.") var file: String
    @Flag(help: "Validate without saving changes.") var dryRun = false
    @Flag(help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let document = try JSONDecoder().decode(
                AttentionRuleDocument.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            let settings = try document.applying(to: AttentionCLI.repository.loadSettings())
            if !dryRun { try AttentionCLI.save(settings: settings) }
            if json {
                CLIOut.json(
                    .object([
                        "rules": .int(document.rules.count),
                        "categories": .int(document.categories.count), "saved": .bool(!dryRun),
                    ]))
            } else {
                CLIOut.out("\(dryRun ? "validated" : "saved") \(document.rules.count) rules")
            }
        }
    }
}
