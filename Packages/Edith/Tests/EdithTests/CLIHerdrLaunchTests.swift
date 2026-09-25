import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIHerdrLaunchTests {
    @Test func modelsListsABuiltInKindWithItsSource() async throws {
        let result = await CLIProbe.run(["herdr", "models", "gemini", "--json"])
        #expect(result.code == 0)
        let kinds = try #require(result.object?["kinds"] as? [[String: Any]])
        #expect(kinds.count == 1)
        let gemini = try #require(kinds.first)
        #expect(gemini["kind"] as? String == "Gemini")
        #expect(gemini["source"] as? String == "built in")
        #expect(gemini["live"] as? Bool == false)
        let models = gemini["models"] as? [[String: Any]] ?? []
        #expect(
            models.compactMap { $0["id"] as? String } == ["auto", "pro", "flash", "flash-lite"])
        #expect(
            Set(models.first?.keys ?? [:].keys)
                == ["id", "name", "summary", "efforts", "defaultEffort", "fast", "fastSummary"])
    }

    @Test func modelsShowsClaudeFastModeAndEfforts() async throws {
        let result = await CLIProbe.run(["herdr", "models", "Claude Code", "--json"])
        let claude = try #require((result.object?["kinds"] as? [[String: Any]])?.first)
        let models = claude["models"] as? [[String: Any]] ?? []
        let opus = try #require(models.first { $0["id"] as? String == "opus" })
        #expect(opus["fast"] as? Bool == true)
        let efforts = (opus["efforts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        #expect(efforts == ["low", "medium", "high", "xhigh", "max"])
    }

    @Test func aKindWithoutOptionsIsNotFound() async {
        let result = await CLIProbe.run(["herdr", "models", "copilot", "--json"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stdout.isEmpty)
    }

    @Test func setStoresTheDefaultsAndLsReadsThemBack() async {
        await CLIProbe.inWorld { world in
            let set = await CLIProbe.capture([
                "herdr", "defaults", "set", "claude", "--model", "opus", "--effort", "max",
                "--fast", "on", "--json",
            ])
            #expect(set.code == 0)
            #expect(set.object?["model"] as? String == "opus")
            #expect(
                set.object?["arguments"] as? [String]
                    == [
                        "--model", "opus", "--effort", "max", "--settings",
                        #"{"fastMode":true}"#,
                    ])
            #expect(
                HerdrLaunchSettings.options(for: "Claude Code", in: world.shared)
                    == AgentLaunchOptions(model: "opus", effort: "max", fast: true))

            let list = await CLIProbe.capture(["herdr", "defaults", "ls", "--json"])
            let rows = list.object?["defaults"] as? [[String: Any]] ?? []
            #expect(rows.count == AgentLaunchKind.allCases.count)
            let claude = rows.first { $0["kind"] as? String == "Claude Code" }
            #expect(claude?["fast"] as? Bool == true)

            let cleared = await CLIProbe.capture([
                "herdr", "defaults", "set", "claude", "--model", "none", "--effort", "none",
                "--fast", "off", "--json",
            ])
            #expect(cleared.code == 0)
            #expect(HerdrLaunchSettings.options(for: "Claude Code", in: world.shared) == .none)
        }
    }

    @Test func invalidCombinationsExitTwoAndStoreNothing() async {
        await CLIProbe.inWorld { world in
            for arguments in [
                ["herdr", "defaults", "set", "claude", "--model", "sonnet", "--fast", "on"],
                ["herdr", "defaults", "set", "claude", "--model", "haiku", "--effort", "high"],
                ["herdr", "defaults", "set", "amp", "--model", "turbo"],
                ["herdr", "defaults", "set", "gemini", "--effort", "high"],
                ["herdr", "defaults", "set", "gemini", "--fast", "maybe"],
                ["herdr", "defaults", "set", "gemini"],
            ] {
                let result = await CLIProbe.capture(arguments + ["--json"])
                #expect(result.code == ExitCodes.usage, "\(arguments)")
                #expect(result.stdout.isEmpty)
            }
            #expect(world.shared.dictionary(forKey: AppStorageKeys.Herdr.launchDefaults) == nil)
        }
    }
}
