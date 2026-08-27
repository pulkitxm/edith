import ArgumentParser
import EdithKit
import Foundation

struct CommandBarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "command-bar",
        abstract: "Calculate and convert with the Command Bar engine.",
        subcommands: [CommandBarCalculateCommand.self, CommandBarConvertCommand.self],
        defaultSubcommand: CommandBarCalculateCommand.self)
}

struct CommandBarCalculateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calculate", abstract: CommandBarOperation.calculate.descriptor.summary)

    @Argument(parsing: .remaining, help: "The arithmetic expression to evaluate.")
    var expression: [String]

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let input = expression.joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard let answer = CommandBarEvaluator.calculation(input) else {
                throw CLIFailure.usage(
                    "could not evaluate the expression",
                    hint: "use numbers, parentheses, +, -, *, /, ^ and %")
            }
            if json {
                CLIOut.json(
                    .object([
                        "formatted": .string(answer.formatted),
                        "kind": .string(answer.kind.rawValue),
                        "operation": .string(CommandBarOperation.calculate.descriptor.id.rawValue),
                        "value": .double(answer.value),
                    ]))
            } else {
                CLIOut.out(answer.formatted)
            }
        }
    }
}

struct CommandBarConvertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert", abstract: CommandBarOperation.convert.descriptor.summary)

    @Argument(help: "The numeric value to convert.")
    var value: Double

    @Argument(help: "The source unit, such as km, lb, or celsius.")
    var source: String

    @Argument(help: "The destination unit, such as mi, kg, or fahrenheit.")
    var destination: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let input = "\(value) \(source) to \(destination)"
            guard let answer = CommandBarEvaluator.conversion(input) else {
                throw CLIFailure.usage(
                    "could not convert (source) to (destination)",
                    hint:
                        "use compatible length, mass, temperature, data, duration, or volume units")
            }
            if json {
                CLIOut.json(
                    .object([
                        "formatted": .string(answer.formatted),
                        "from": .string(source),
                        "kind": .string(answer.kind.rawValue),
                        "operation": .string(CommandBarOperation.convert.descriptor.id.rawValue),
                        "to": .string(destination),
                        "value": .double(answer.value),
                    ]))
            } else {
                CLIOut.out(answer.formatted)
            }
        }
    }
}
