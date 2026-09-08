import Foundation
import Testing

@testable import EdithCLI

@Suite struct CLICommandBarTests {
    @Test func calculationPrintsPlainAndStructuredResults() async {
        let plain = await CLIProbe.run(["command-bar", "calculate", "2", "+", "3", "*", "4"])
        let json = await CLIProbe.run([
            "command-bar", "calculate", "2", "+", "3", "*", "4", "--json",
        ])

        #expect(plain.code == 0)
        #expect(plain.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "14")
        #expect(json.code == 0)
        #expect(json.object?["operation"] as? String == "commandBar.calculate")
        #expect(json.object?["value"] as? Double == 14)
    }

    @Test func conversionPrintsPlainAndStructuredResults() async {
        let plain = await CLIProbe.run(["command-bar", "convert", "5", "km", "mi"])
        let json = await CLIProbe.run([
            "command-bar", "convert", "72", "fahrenheit", "celsius", "--json",
        ])

        #expect(plain.code == 0)
        #expect(plain.stdout.contains("mi"))
        #expect(json.code == 0)
        #expect(json.object?["operation"] as? String == "commandBar.convert")
        #expect(json.object?["to"] as? String == "celsius")
    }

    @Test func invalidInputIsAUsageError() async {
        let expression = await CLIProbe.run(["command-bar", "calculate", "2", "+"])
        let conversion = await CLIProbe.run(["command-bar", "convert", "5", "km", "kg"])

        #expect(expression.code == ExitCodes.usage)
        #expect(expression.stderr.contains("could not evaluate"))
        #expect(conversion.code == ExitCodes.usage)
        #expect(conversion.stderr.contains("could not convert"))
    }
}
