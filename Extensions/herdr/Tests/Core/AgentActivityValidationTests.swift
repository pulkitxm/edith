import EdithExtensionSupport
import Foundation
import Testing

@testable import HerdrUI

@Suite struct AgentActivityValidationTests {
    @Test func malformedDirectEventsCannotAllocateSessionsOrApprovals() async {
        let service = AgentActivityService(
            settings: {
                .init(providers: ["claude": .init(observing: true, approvals: true)])
            }, listener: { true })
        var event = AgentActivityEvent(
            provider: .claude, sessionID: "synthetic", eventName: "PreToolUse",
            phase: .working, project: "/tmp/synthetic")
        event.permissionRequest = true
        event.tool = "Bash"
        #expect(await service.ingest(event).token == nil)
        event.permissionRequest = false
        event.detail = String(repeating: "x", count: 131_073)
        #expect(await service.ingest(event).token == nil)
        event.detail = nil
        event.receivedAt = Date(timeIntervalSince1970: .infinity)
        #expect(await service.ingest(event).token == nil)
        #expect(await service.snapshot().sessions.isEmpty)
    }

    @Test(arguments: AgentActivityProvider.allCases)
    func providerSetupUsesOriginalPublicSameExecutableHook(_ provider: AgentActivityProvider) throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith.app/Contents/MacOS/Edith"))
        let plan = try installer.plan(provider: provider, enabled: true)
        let text = String(decoding: try #require(plan.replacement), as: UTF8.self)
        #expect(text.contains("--provider"))
        #expect(text.contains(provider.rawValue))
        #expect(text.contains("--integration-id"))
        #expect(text.contains("edith-surfaces"))
        #expect(text.contains("TMUX_PANE"))
        #expect(!text.contains("activity.hook."))
        #expect(!text.contains("Contents/MacOS/ed\""))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
