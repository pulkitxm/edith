import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

extension MachineCLITests {
    @Suite @MainActor struct MachineConfigAndCompletionTests {
        @Test func originalConfigCommandsUseOnlyOwningDefaultsAndPreserveImportPlans() async throws
        {
            let defaults = SharedDefaults.store
            let keys = ["machinesMode", "dockerLogWrap", "finderShowHidden"]
            let previous = keys.map { ($0, defaults.object(forKey: $0)) }
            defer {
                for (key, value) in previous {
                    if let value {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
            func run(_ arguments: [String], input: Data = Data()) async throws -> ExtensionCLIReply
            {
                try await ExtensionCLIExecution.run(
                    ConfigCommand.self,
                    request: ExtensionCLIRequest(arguments: arguments, standardInput: input))
            }
            let set = try await run(["set", "machinesMode", "workspace", "--json"])
            #expect(set.exitCode == 0)
            #expect(defaults.string(forKey: "machinesMode") == "workspace")
            let invalid = try await run(["set", "machinesMode", "unknown"])
            #expect(invalid.exitCode != 0)
            #expect(invalid.stderr.contains("not a valid value"))
            #expect(defaults.string(forKey: "machinesMode") == "workspace")
            let input = Data(
                #"{"dockerLogWrap":false,"finderShowHidden":true,"unownedSetting":true}"#.utf8)
            let preview = try await run(["import", "-", "--dry-run", "--json"], input: input)
            #expect(preview.exitCode == 0)
            #expect(preview.stdout.contains("unownedSetting"))
            let imported = try await run(["import", "-", "--json"], input: input)
            #expect(imported.exitCode == 0)
            #expect(!defaults.bool(forKey: "dockerLogWrap"))
            #expect(defaults.bool(forKey: "finderShowHidden"))
            let unset = try await run(["unset", "machinesMode"])
            #expect(unset.stdout == "machinesMode = fleet\n")
            #expect(ConfigCatalog.keys.count == 15)
            #expect(throws: CLIFailure.self) {
                try ConfigValueParser.parse("nan", as: .number, allowed: [])
            }
        }

        @Test func catalogIncludesOriginalParserArgumentsAndOwningSettings() throws {
            let object = try #require(
                JSONSerialization.jsonObject(with: MachineCLICatalog.encoded()) as? [String: Any])
            let settings = try #require(object["settings"] as? [[String: Any]])
            #expect(settings.count == 15)
            let mode = try #require(settings.first { $0["key"] as? String == "machinesMode" })
            #expect(mode["allowed"] as? [String] == ["fleet", "workspace", "machine"])
            #expect(mode["fallback"] as? String == "fleet")
            let documents = try #require(object["parserHelp"] as? [[String: Any]])
            #expect(documents.count == 1)
            #expect(documents[0]["serializationVersion"] as? Int == 0)
            let parser = try #require(documents[0]["command"] as? [String: Any])
            #expect(parser["commandName"] as? String == "machines")
            let children = try #require(parser["subcommands"] as? [[String: Any]])
            let exec = try #require(children.first { $0["commandName"] as? String == "exec" })
            #expect((exec["arguments"] as? [[String: Any]])?.isEmpty == false)
        }

        @Test func originalMachineFirstCompletionPreservesFlagsFilesAliasesAndPassthrough() {
            func plan(_ words: [String]) -> CompletionResult {
                CompletionEngine.plan(
                    .init(words: words, index: words.count - 1), machines: ["fixture-box"])
            }
            #expect(plan(["ed", "machines", ""]).candidates.contains("fixture-box"))
            #expect(plan(["ed", "machines", "fixture-box", ""]).candidates.contains("docker"))
            #expect(
                plan(["ed", "machines", "files", "ls", "fixture-box", "--a"]).candidates.contains(
                    "--all"))
            #expect(
                plan(["ed", "machines", "fixture-box", "docker", ""]).candidates.contains("logs"))
            #expect(
                plan(["ed", "machines", "files", "get", "fixture-box", "/remote/path", "--to", ""])
                    .wantsFiles)
            let passthrough = plan(["ed", "machines", "exec", "fixture-box", "--", "ls", ""])
            #expect(passthrough.remoteMachine == "fixture-box")
            #expect(passthrough.remoteRequest?.words == ["ed", "fixture-box", "ls", ""])
            #expect(plan(["ed", "fixture-box", "ls", ""]).remoteMachine == "fixture-box")
        }
    }
}
