import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct ColorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "List, copy, and clear colours picked with Edith's colour picker.",
        discussion: """
            List, copy, and clear colours picked with Edith's colour picker.
            Reads the colour store. copy changes the pasteboard. clear changes the store after --yes. ls does not change anything.

            ed color ls
            ed color copy 1 --format hex
            """,
        subcommands: [
            ColorPickCommand.self, ColorListCommand.self, ColorCopyCommand.self,
            ColorClearCommand.self,
        ],
        defaultSubcommand: ColorListCommand.self,
        aliases: ["colour"])
}

@MainActor enum ColorBridge {
    static func format(_ name: String) throws -> ColorCopyFormat {
        guard let format = ColorCopyFormat(rawValue: name) else {
            throw CLIFailure.notFound(
                "no colour format named \(name)",
                hint: "formats: "
                    + ColorCopyFormat.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return format
    }

    static func swatch(at index: Int) throws -> ColorSwatch {
        let history = ColorHistoryStore.load(from: ColorCLIEnvironment.defaults)
        guard !history.isEmpty else {
            throw CLIFailure.unavailable(
                "the colour history is empty",
                hint: "run `ed color pick`, then choose a colour")
        }
        guard index >= 1, index <= history.count else {
            throw CLIFailure.notFound(
                "there is no colour \(index)",
                hint: "the history holds \(history.count) colours, numbered from 1")
        }
        return history[index - 1]
    }
}

struct ColorPickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pick", abstract: "Open Edith's system colour sampler.",
        discussion: """
            Open the system colour sampler and store the colour you pick.
            Reads nothing until you pick. Changes the colour store when a colour is chosen. Someone at the Mac has to select it.

            ed color pick
            ed color pick --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            guard
                ColorCLIEnvironment.defaults.object(forKey: AppStorageKeys.ColorPicker.enabled)
                    as? Bool == true
            else {
                throw CLIFailure.unavailable(
                    "the Color Picker extension is off",
                    hint: "run `ed extensions enable colorPicker`, then retry")
            }
            ColorCLIEnvironment.pick()
            let descriptor = ColorPickerOperation.pick.descriptor
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "requested": .bool(true),
                    ]))
                return
            }
            CLIOut.out("color picker requested")
        }
    }
}

struct ColorListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List picked colours, newest first.",
        discussion: """
            List picked colours, newest first.
            Reads the colour store. Does not change it.

            ed color ls
            ed color ls --format hex --json
            """, aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Print each colour in one format: hex, rgb, hsl, swiftUI or nsColor.")
    var format: String?

    @Option(help: "Show at most this many colours.")
    var limit: Int = 25

    @MainActor func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            var chosen: ColorCopyFormat?
            if let format {
                chosen = try ColorBridge.format(format)
            }
            let stored = ColorHistoryStore.load(from: ColorCLIEnvironment.defaults)
            let swatches = limit == 0 ? stored : Array(stored.prefix(limit))
            guard !json else {
                CLIOut.json(
                    .array(
                        swatches.map { swatch in
                            .object([
                                "hex": .string(swatch.string(for: .hex)),
                                "rgb": .string(swatch.string(for: .rgb)),
                                "hsl": .string(swatch.string(for: .hsl)),
                                "profile": .string(swatch.profile.rawValue),
                                "pickedAt": .date(swatch.pickedAt),
                            ])
                        }))
                return
            }
            if let chosen {
                for swatch in swatches { CLIOut.out(swatch.string(for: chosen)) }
                return
            }
            guard !swatches.isEmpty else {
                CLIOut.note("no colours picked yet")
                return
            }
            let rows = swatches.map { swatch in
                [
                    swatch.string(for: .hex), swatch.string(for: .rgb),
                    swatch.profile.displayName,
                    JSONSerializer.iso.string(from: swatch.pickedAt),
                ]
            }
            CLIOut.out(
                TextTable.render(headers: ["HEX", "RGB", "PROFILE", "PICKED"], rows: rows))
        }
    }
}

struct ColorCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy", abstract: "Copy one picked colour to the pasteboard.",
        discussion: """
            Copy one picked colour to the pasteboard.
            Reads that colour. Changes the pasteboard. --format selects hex, css, or the configured default.

            ed color copy 1
            ed color copy 1 --format hex
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Copy as hex, rgb, hsl, swiftUI or nsColor.")
    var format: String?

    @Argument(help: "The colour number, counting from 1.")
    var index: Int

    @MainActor func run() async throws {
        try await execute {
            let swatch = try ColorBridge.swatch(at: index)
            let configured =
                ColorCLIEnvironment.defaults.string(
                    forKey: AppStorageKeys.ColorPicker.copyFormat) ?? ColorCopyFormat.hex.rawValue
            let chosen =
                try format.map(ColorBridge.format)
                ?? ColorCopyFormat(rawValue: configured) ?? .hex
            let result: ColorSwatchOperationResult
            do {
                result = try ColorSwatchOperationExecution.perform(
                    .copy, swatch: swatch, format: chosen,
                    write: { value in
                        ColorCLIEnvironment.write(value)
                    })
            } catch let error as ColorSwatchOperationError {
                throw CLIFailure.unavailable(
                    error.localizedDescription,
                    hint: "check pasteboard access, then retry")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(result.operation.descriptor.id.rawValue),
                        "index": .int(index),
                        "id": .string(result.swatchID.uuidString),
                        "format": .string(result.format.rawValue),
                        "value": .string(result.value),
                        "copied": .bool(true),
                    ]))
                return
            }
            CLIOut.out("copied colour \(index) as \(result.value)")
        }
    }
}

struct ColorClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget every picked colour.",
        discussion: """
            Delete every picked colour.
            Reads the colour store. Without --yes, does not change anything. With --yes, changes the store by clearing it.

            ed color clear
            ed color clear --yes
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually clear it. Without this nothing is touched.")
    var yes = false

    @MainActor func run() async throws {
        try await execute {
            let swatches = ColorHistoryStore.load(from: ColorCLIEnvironment.defaults)
            let plan = CLIDestructivePlan(
                action: "clear color history", targets: swatches.map { $0.id.uuidString },
                confirmed: yes, json: json, fields: ["removed": .int(swatches.count)])
            guard plan.shouldApply() else { return }
            ColorHistoryStore.clear(in: ColorCLIEnvironment.defaults)
            ColorCLIEnvironment.changed()
            plan.finish(
                changed: !swatches.isEmpty, plain: "cleared \(swatches.count) colours")
        }
    }
}
