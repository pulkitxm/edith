import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import DocsExtension

@Suite(.serialized) @MainActor struct DocsRuntimeTests {
    @Test func stoppedRuntimeCannotAllocateOrAcceptEngineWork() async {
        let runtime = ExtensionRuntime()
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        let suite = ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"] ?? ""
        let result =
            runtime.execute(["operation": "start", "defaultsSuite": suite]) as? NSDictionary
        #expect(result?["ok"] as? Bool == false)
        let status = runtime.execute(["operation": "status"]) as? NSDictionary
        #expect(status?["running"] as? Bool == false)
    }

    @Test func closingOnePresentationDoesNotSuspendAnotherPresentationsCopyFeedback() async {
        DocsCopyResetWork.beginSuspension()
        await DocsCopyResetWork.drain()
        DocsCopyResetWork.enable()
        let runtime = ExtensionRuntime()
        let lease = DocsSharedResourceLease()
        ExtensionUIResources.bind(lease, to: runtime)
        _ = runtime.execute(["operation": "stopUI"])
        #expect(DocsCopyResetWork.schedule(UUID(), reset: {}))
        lease.finish()
        #expect(!DocsCopyResetWork.schedule(UUID(), reset: {}))
        await DocsCopyResetWork.drain()
        DocsCopyResetWork.enable()
    }

    @Test func answersTheCLICatalogWithoutTheBuiltInHelpCommand() throws {
        let data = try ExtensionCLICatalog.data(
            DocsCommandGroup.self, owner: "docs", payload: Data("{}".utf8), streaming: true)
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["owner"] as? String == "docs")
        let commands = try #require(value["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes.contains(["docs", "ask"]))
        #expect(!routes.contains { $0.last == "help" })
        let help = try #require((value["parserHelp"] as? [[String: Any]])?.first)
        let root = try #require(help["command"] as? [String: Any])
        let names = (root["subcommands"] as? [[String: Any]] ?? []).compactMap {
            $0["commandName"] as? String
        }
        #expect(!names.contains("help"))
    }
}

@MainActor
private final class DocsSharedResourceLease: NSObject {
    private var pending: (@convention(block) () -> Void)?

    @objc(scheduleSharedCleanup:operation:)
    func scheduleSharedCleanup(_ key: NSString, operation: @escaping @convention(block) () -> Void)
    {
        pending = operation
    }

    @objc func canStopSharedResources() -> Bool { false }

    func finish() { pending?(); pending = nil }
}
