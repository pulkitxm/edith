import ArgumentParser
import EdithKit

struct ScratchpadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scratchpad",
        abstract: "Evaluate arithmetic and unit conversions with Scratchpad.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(parsing: .remaining, help: "An expression such as `2 + 2` or `10 km to mi`.")
    var expression: [String] = []

    func run() async throws {
        try await execute {
            let input = expression.joined(separator: " ")
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure.usage(
                    "scratchpad needs an expression",
                    hint: "try `ed scratchpad \"2 + 2\"` or `ed scratchpad \"10 km to mi\"`")
            }
            guard let result = QuickCalc.evaluate(input) else {
                throw CLIFailure.usage(
                    "could not evaluate \(input)",
                    hint: "use arithmetic or a conversion such as `10 km to mi`")
            }
            guard !json else {
                CLIOut.json(
                    .object(["input": .string(input), "result": .string(result)]))
                return
            }
            CLIOut.out(result)
        }
    }
}
