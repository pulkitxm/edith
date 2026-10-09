import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite(.serialized) struct HerdrAgentHookLiveTests {
    private static let sessionKey = "EDITH_HERDR_HOOK_LIVE_SESSION"
    private static let paneKey = "EDITH_HERDR_HOOK_LIVE_PANE"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[sessionKey] != nil))
    func aRealHerdrAgentGetsTheMessageOnceAfterItFinishes() async throws {
        let environment = ProcessInfo.processInfo.environment
        let session = try #require(environment[Self.sessionKey])
        let pane = try #require(environment[Self.paneKey])
        try #require(session.hasPrefix("edith-integration-"))
        func received() async throws -> String {
            try await HerdrCommand.run(
                HerdrSessionCommand.scoped(
                    ["agent", "read", pane, "--source", "visible"],
                    session: session), timeout: 5, on: nil
            )
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        }

        let receipt = UUID().uuidString
        let message =
            "Reply with exactly HOOK_OK. Do not use tools, read files, or change files. Request: \(receipt)"
        #expect(!(try await received()).contains(receipt))
        _ = try await HerdrCommand.run(
            HerdrSessionCommand.scoped(
                [
                    "agent", "prompt", pane,
                    "Reply with the numbers 1 through 200 separated by spaces. Do not use tools, read files, or change files.",
                    "--wait", "--until", "working", "--timeout", "15000",
                ], session: session), timeout: 20, on: nil)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHooksLive.\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = AgentHookService(url: url)
        guard
            case .agent(let observed) = await HerdrAgentPrompt.probe(
                session: session, pane: pane, machineID: HerdrHostSnapshot.localID, local: true)
        else {
            Issue.record("herdr did not report the agent")
            return
        }
        try #require(observed.status == .working)
        let agent = HerdrAgent.make(
            machineID: HerdrHostSnapshot.localID, machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: session, pane: pane, kind: observed.kind,
            status: observed.status, title: "live", workspace: "", cwd: "",
            stateSequence: observed.sequence)
        _ = try await service.arm(
            HerdrHookArmRequest(agent: agent, message: message))

        await service.tick()
        #expect(!(try await received()).contains(receipt))
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while await service.list().hooks.first?.phase == .armed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            await service.tick()
        }
        await service.tick()
        try await Task.sleep(for: .milliseconds(500))

        let hook = try #require(await service.list().hooks.first)
        #expect(hook.phase == .sent)
        #expect(hook.detail == "Submitted")
        #expect(try await received().components(separatedBy: receipt).count - 1 == 1)
    }
}
