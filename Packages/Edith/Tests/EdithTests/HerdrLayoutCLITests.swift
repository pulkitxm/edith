import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct HerdrLayoutCLITests {
    @Test func requestsRoundTrip() throws {
        let request = HerdrLayoutRequest.split(agent: "agent-1", side: "right")
        let encoded = try #require(request.encoded)
        #expect(HerdrLayoutRequest.decode(encoded) == request)
        let runtime = HerdrLayoutRuntimeRequest(
            request: request, deadline: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = try #require(runtime.payload)
        let decoded = try #require(HerdrLayoutRuntimeRequest(payload: payload))
        #expect(decoded.request == request)
        #expect(decoded.requestID == runtime.requestID)
    }

    @Test func tabResolutionPrefersAnIdOverASharedTitle() throws {
        let snapshot = Self.sample
        let tab = try HerdrLayoutCLI.tab("tab-b", in: snapshot)
        #expect(tab.index == 2)
        let selected = try HerdrLayoutCLI.tab(nil, in: snapshot)
        #expect(selected.id == "tab-a")
        #expect(throws: CLIFailure.self) { try HerdrLayoutCLI.tab("0", in: snapshot) }
    }

    @Test func agentResolutionAcceptsAPaneAndRejectsAmbiguousTitles() throws {
        let agent = try HerdrLayoutCLI.agent("w3:p1", in: Self.sample)
        #expect(agent.id == "agent-1")
        #expect(throws: CLIFailure.self) { try HerdrLayoutCLI.agent("Same", in: Self.sample) }
    }

    @Test func sideNamesAreTheFourEdges() throws {
        #expect(try HerdrLayoutCLI.side(" Right ") == "right")
        #expect(throws: CLIFailure.self) { try HerdrLayoutCLI.side("beside") }
    }

    @Test func helpNamesTheLayoutExample() {
        let help = HerdrLayoutListCommand.helpMessage(columns: 200)
        #expect(help.contains("ed herdr layout ls --json"))
    }

    private static let sample = HerdrLayoutSnapshot(
        selected: "tab-a",
        tabs: [
            HerdrLayoutTabState(
                id: "board", index: 0, title: "Board", agents: [], focused: "", selected: false),
            HerdrLayoutTabState(
                id: "tab-a", index: 1, title: "Same",
                agents: [
                    HerdrLayoutAgentState(id: "agent-1", title: "Same", pane: "w3:p1")
                ],
                focused: "agent-1", selected: true),
            HerdrLayoutTabState(
                id: "tab-b", index: 2, title: "Same",
                agents: [
                    HerdrLayoutAgentState(id: "agent-2", title: "Same", pane: "w3:p2")
                ],
                focused: "agent-2", selected: false),
        ],
        arrangements: [
            HerdrLayoutArrangementState(id: "saved-1", name: "Pair", panes: 2)
        ],
        agents: [
            HerdrLayoutAgentState(id: "agent-1", title: "Same", pane: "w3:p1"),
            HerdrLayoutAgentState(id: "agent-2", title: "Same", pane: "w3:p2"),
        ],
        terminals: [])
}
