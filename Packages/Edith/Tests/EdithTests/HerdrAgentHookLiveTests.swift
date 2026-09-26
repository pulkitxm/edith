import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite(.serialized) struct HerdrAgentHookLiveTests {
    private static let sessionKey = "EDITH_HERDR_HOOK_LIVE_SESSION"
    private static let paneKey = "EDITH_HERDR_HOOK_LIVE_PANE"
    private static let transcriptKey = "EDITH_HERDR_HOOK_LIVE_TRANSCRIPT"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[sessionKey] != nil))
    func aRealHerdrAgentGetsTheMessageOnceAfterItFinishes() async throws {
        let environment = ProcessInfo.processInfo.environment
        let session = try #require(environment[Self.sessionKey])
        let pane = try #require(environment[Self.paneKey])
        let transcript = URL(fileURLWithPath: try #require(environment[Self.transcriptKey]))
        let herdr = try #require(HerdrCollector.executable())
        func report(_ state: String) throws {
            let process = Process()
            process.executableURL = herdr
            process.arguments = [
                "--session", session, "pane", "report-agent", pane, "--source", "edith-live-test",
                "--agent", "claude", "--state", state,
            ]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        func received() -> [String] {
            ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        try report("idle")
        let before = received().count
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
        let agent = HerdrAgent.make(
            machineID: HerdrHostSnapshot.localID, machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: session, pane: pane, kind: observed.kind,
            status: observed.status, title: "live", workspace: "", cwd: "",
            stateSequence: observed.sequence)
        _ = try await service.arm(
            HerdrHookArmRequest(agent: agent, message: "hook fired after the turn"))

        await service.tick()
        #expect(received().count == before)
        try report("working")
        await service.tick()
        #expect(received().count == before)
        try report("idle")
        await service.tick()
        await service.tick()
        try await Task.sleep(for: .milliseconds(500))

        let hook = try #require(await service.list().hooks.first)
        #expect(hook.phase == .sent)
        #expect(hook.detail == "Submitted")
        #expect(Array(received().dropFirst(before)) == ["hook fired after the turn"])
    }
}
