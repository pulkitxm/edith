import Foundation
import Testing

@testable import EdithKit

@Suite struct HerdrBoardCacheTests {
    @Test func tufWiredAgentsStayPutWhenStatusChanges() {
        let cache = HerdrBoardCache(context: tuf)
        cache.applySnapshot(tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        #expect(cache.agents.map(\.pane) == ["w3:p1N", "w3:p1Q"])
        #expect(Set(cache.agents.map(\.status)) == [.idle])

        let afterWorking = cache.applyEvent(
            paneUpdated(
                pane: "w3:p1N", agent: "opencode", status: "working", title: "Image Query"))
        #expect(afterWorking.count == 2)
        #expect(afterWorking.first { $0.pane == "w3:p1N" }?.status == .working)
        #expect(afterWorking.first { $0.pane == "w3:p1N" }?.kind == "OpenCode")
        #expect(afterWorking.first { $0.pane == "w3:p1N" }?.title == "Image Query")
        #expect(afterWorking.first { $0.pane == "w3:p1Q" }?.status == .idle)
        #expect(
            afterWorking.first { $0.pane == "w3:p1N" }?.id
                == "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB|default|w3:p1N")

        let afterIdle = cache.applyEvent(
            paneUpdated(pane: "w3:p1N", agent: "opencode", status: "idle", title: "Image Query"))
        #expect(afterIdle.count == 2)
        #expect(afterIdle.first { $0.pane == "w3:p1N" }?.status == .idle)
        #expect(Set(afterIdle.map(\.id)).count == 2)
    }

    @Test func snapshotThatDropsAgentsKeepsTheLivePanes() {
        let cache = HerdrBoardCache(context: tuf)
        cache.applySnapshot(tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        cache.applyEvent(
            paneUpdated(
                pane: "w3:p1N", agent: "opencode", status: "working", title: "Image Query"))
        let kept = cache.applySnapshot(
            tufSnapshot(agents: false, queryStatus: "unknown", boardStatus: "unknown", hollow: true)
        )
        #expect(kept.count == 2)
        #expect(kept.first { $0.pane == "w3:p1N" }?.status == .working)
        #expect(kept.first { $0.pane == "w3:p1N" }?.kind == "OpenCode")
        #expect(kept.first { $0.pane == "w3:p1N" }?.title == "Image Query")
        #expect(kept.first { $0.pane == "w3:p1Q" }?.kind == "Claude Code")
    }

    @Test func subscribeReplayDoesNotWipeOrInventPanes() {
        let cache = HerdrBoardCache(context: tuf)
        cache.applySnapshot(tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        cache.applyEvent(
            #"{"event":"pane_created","data":{"type":"pane_created","pane":{"pane_id":"w3:p1N","agent":null,"agent_status":"unknown","terminal_title_stripped":null,"workspace_id":"w3"}}}"#
        )
        cache.applyEvent(
            #"{"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"w9:ghost","agent":"claude","agent_status":"idle","terminal_title_stripped":"Ghost","workspace_id":"w9"}}}"#
        )
        cache.applyEvent(
            #"{"event":"pane_agent_detected","data":{"type":"pane_agent_detected","agent":"opencode","final_status":"idle","pane_id":"w3:p1N","released":true,"workspace_id":"w3"}}"#
        )
        #expect(cache.agents.map(\.pane) == ["w3:p1N", "w3:p1Q"])
        #expect(cache.agents.first { $0.pane == "w3:p1N" }?.kind == "OpenCode")
        #expect(cache.agents.first { $0.pane == "w3:p1N" }?.status == .idle)
        #expect(cache.agents.first { $0.pane == "w3:p1N" }?.title == "Image Query")
    }

    @Test func aReleasedTurnTakesTheFinalStatusWithoutDroppingTheCard() {
        let cache = HerdrBoardCache(context: tuf)
        cache.applySnapshot(tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        cache.applyEvent(
            paneUpdated(
                pane: "w3:p1N", agent: "opencode", status: "working", title: "Image Query"))
        #expect(cache.agents.first { $0.pane == "w3:p1N" }?.status == .working)
        cache.applyEvent(
            #"{"event":"pane_agent_detected","data":{"type":"pane_agent_detected","agent":"opencode","final_status":"idle","pane_id":"w3:p1N","released":true,"workspace_id":"w3"}}"#
        )
        #expect(cache.agents.map(\.pane) == ["w3:p1N", "w3:p1Q"])
        #expect(cache.agents.first { $0.pane == "w3:p1N" }?.status == .idle)
        #expect(cache.agents.first { $0.pane == "w3:p1N" }?.kind == "OpenCode")
        #expect(cache.agents.first { $0.pane == "w3:p1N" }?.title == "Image Query")
        #expect(cache.agents.first { $0.pane == "w3:p1Q" }?.status == .idle)
    }

    @Test func aLaterSnapshotWinsOverAStaleWorkingEvent() {
        let cache = HerdrBoardCache(context: tuf)
        cache.applySnapshot(tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        cache.applyEvent(
            paneUpdated(
                pane: "w3:p1N", agent: "opencode", status: "working", title: "Image Query"))
        cache.applyEvent(
            paneUpdated(
                pane: "w3:p1Q", agent: "claude", status: "working", title: "Waiting on a key"))
        #expect(Set(cache.agents.map(\.status)) == [.working])
        let restored = cache.applySnapshot(
            tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        #expect(Set(restored.map(\.status)) == [.idle])
        #expect(restored.map(\.pane) == ["w3:p1N", "w3:p1Q"])
        #expect(restored.first { $0.pane == "w3:p1N" }?.title == "Image Query")
    }

    @Test func paneClosedDropsOnlyThatCard() {
        let cache = HerdrBoardCache(context: tuf)
        cache.applySnapshot(tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        cache.applyEvent(
            #"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w3:p1Q","workspace_id":"w3"}}"#
        )
        #expect(cache.agents.map(\.pane) == ["w3:p1N"])
        #expect(cache.agents[0].kind == "OpenCode")
    }

    @Test func workspaceRenameRelabelsLiveAgents() {
        let cache = HerdrBoardCache(context: tuf)
        cache.applySnapshot(tufSnapshot(agents: true, queryStatus: "idle", boardStatus: "idle"))
        cache.applyEvent(
            #"{"event":"workspace_renamed","data":{"type":"workspace_renamed","workspace":{"workspace_id":"w3","label":"edith-herdr"}}}"#
        )
        #expect(Set(cache.agents.map(\.workspace)) == ["edith-herdr"])
        #expect(cache.agents.count == 2)
    }

    private var tuf: HerdrBoardContext {
        HerdrBoardContext(
            session: "default", machineID: "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB",
            machineName: "tuf-wired", machineIsLocal: false, sshTarget: "tuf-wired")
    }

    private func tufSnapshot(
        agents: Bool, queryStatus: String, boardStatus: String, hollow: Bool = false
    ) -> String {
        let queryPane: String
        let boardPane: String
        if hollow {
            queryPane = """
                {"pane_id":"w3:p1N","agent":null,"agent_status":"unknown","terminal_title_stripped":null,"workspace_id":"w3","foreground_cwd":"/srv/app"}
                """
            boardPane = """
                {"pane_id":"w3:p1Q","agent":null,"agent_status":"unknown","terminal_title_stripped":null,"workspace_id":"w3"}
                """
        } else {
            queryPane = """
                {"pane_id":"w3:p1N","agent":"opencode","agent_status":"\(queryStatus)","terminal_title_stripped":"Image Query","workspace_id":"w3","foreground_cwd":"/srv/app"}
                """
            boardPane = """
                {"pane_id":"w3:p1Q","agent":"claude","agent_status":"\(boardStatus)","terminal_title_stripped":"Waiting on a key","workspace_id":"w3"}
                """
        }
        let agentList =
            agents
            ? "[\(queryPane),\(boardPane)]" : "[]"
        return """
            {"id":"s","result":{"type":"session_snapshot","snapshot":{"panes":[\(queryPane),\(boardPane)],"agents":\(agentList),"workspaces":[{"label":"quinjet","workspace_id":"w3"}]}}}
            """
    }

    private func paneUpdated(pane: String, agent: String, status: String, title: String) -> String {
        """
        {"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"\(pane)","agent":"\(agent)","agent_status":"\(status)","terminal_title_stripped":"\(title)","workspace_id":"w3","cwd":"/srv/app"}}}
        """
    }
}
