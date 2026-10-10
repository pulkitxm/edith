import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import PresenterExtension

@MainActor @Suite(.serialized) struct PresenterCLITests {

    @Test func discoveryCatalogContainsOnlyOriginalParserRoutesAndRejectsForeignPayloads()
        throws
    {
        let data = try PresenterCLIExecution.catalog(Data("{}".utf8))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["version"] as? Int == 1)
        #expect(catalog["owner"] as? String == "presenter")
        #expect(catalog["acceptsInput"] as? Bool == false)
        let commands = try #require(catalog["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        var expected: [[String]] = [
            ["presenter"], ["presenter", "status"], ["presenter", "start"], ["presenter", "stop"],
        ]
        expected.append(["presenter", "help"])
        #expect(Set(routes) == Set(expected))
        #expect(routes.count == Set(routes).count)
        #expect(commands.allSatisfy { $0["operation"] as? String == "presenter.cli" })
        let documents = try #require(catalog["parserHelp"] as? [[String: Any]])
        #expect(documents.count == 1)
        #expect(documents[0]["serializationVersion"] as? Int == 0)
        let help = try #require(documents[0]["command"] as? [String: Any])
        #expect(help["commandName"] as? String == "presenter")

        #expect(throws: (any Error).self) {
            try PresenterCLIExecution.catalog(Data("{\"arguments\":[]}".utf8))
        }
    }

    @Test func originalActionReceivesTheExactCallerContextAndDoesNotLeakIt() async throws {
        let request = try ExtensionCLIRequest(
            arguments: ["start"], standardInput: Data("synthetic terminal input".utf8),
            workingDirectory: "/tmp/synthetic-terminal-context", interactive: true)
        var observed: ExtensionCLIRequest?
        let defaults = UserDefaults(suiteName: "edith.presenter.context." + UUID().uuidString)!
        defaults.set(true, forKey: AppStorageKeys.Presenter.enabled)
        let reply = try await PresenterCLIExecution.run(request, defaults: defaults) { operation in
            observed = ExtensionCLIContext.request
            return PresenterRuntimeOperationExecution.perform(
                operation, defaults: defaults, post: { _ in })
        }
        #expect(reply.exitCode == 0)
        #expect(observed == request)
        #expect(ExtensionCLIContext.request == nil)
    }
    @Test func originalStatusStartStopUseOwnedStateAndExactOutput() async throws {
        let defaults = UserDefaults(suiteName: "edith.presenter.cli." + UUID().uuidString)!
        defaults.set(true, forKey: AppStorageKeys.Presenter.enabled)
        var operations: [PresenterRuntimeOperation] = []
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await PresenterCLIExecution.run(
                ExtensionCLIRequest(arguments: arguments), defaults: defaults
            ) { operation in
                operations.append(operation)
                return PresenterRuntimeOperationExecution.perform(
                    operation, defaults: defaults, post: { _ in })
            }
        }
        let status = try await run(["status"])
        #expect(status.stdout == "inactive\n")
        #expect(status.stderr.isEmpty && status.exitCode == 0)
        #expect(operations.isEmpty)
        let start = try await run(["start"])
        #expect(start.stdout == "presenter mode started\n")
        #expect(defaults.bool(forKey: AppStorageKeys.Presenter.mode))
        defaults.set(true, forKey: AppStorageKeys.Presenter.autoActive)
        defaults.set("Meeting", forKey: AppStorageKeys.Presenter.autoReason)
        let stop = try await run(["stop", "--json"])
        let value = try #require(
            JSONSerialization.jsonObject(with: Data(stop.stdout.utf8)) as? [String: Any])
        #expect(value["manual"] as? Bool == false)
        #expect(value["autoActive"] as? Bool == true)
        #expect(value["autoReason"] as? String == "Meeting")
        #expect(operations == [.start, .stop])
        defaults.set(false, forKey: AppStorageKeys.Presenter.enabled)
        let disabled = try await run(["start"])
        #expect(disabled.exitCode == 4)
        #expect(disabled.stdout.isEmpty)
        #expect(disabled.stderr.contains("the Presenter extension is off"))
        #expect(operations == [.start, .stop])
    }
}
