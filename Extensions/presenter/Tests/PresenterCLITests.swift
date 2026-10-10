import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import PresenterExtension

@MainActor @Suite(.serialized) struct PresenterCLITests {
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
