import Foundation
import Testing

@testable import EdithKit

@Suite struct HerdrTerminalTests {
    @Test func snapshotSeparatesTerminalsFromAgents() {
        let agents = HerdrListParser.agents(
            fromSnapshot: snapshot, session: "default", machineID: "local",
            machineName: "This Mac", machineIsLocal: true, sshTarget: nil)
        #expect(agents.map(\.pane) == ["w2:p1", "w2:p6"])
        let agent = try? #require(agents.first { $0.pane == "w2:p1" })
        #expect(agent?.category == .agent)
        #expect(agent?.kind == "Claude Code")
        let terminal = try? #require(agents.first { $0.pane == "w2:p6" })
        #expect(terminal?.category == .terminal)
        #expect(terminal?.isTerminal == true)
        #expect(terminal?.kind == HerdrKind.terminalLabel)
        #expect(terminal?.title == "site dev server")
        #expect(terminal?.cwd == "/repo/apps/site")
    }

    @Test func aTerminalWithoutATabLabelFallsBackToItsPane() {
        let json = """
            {"id":"s","result":{"type":"session_snapshot","snapshot":{"panes":[{"pane_id":"w1:pA","agent_status":"unknown","tab_id":"w1:tA","workspace_id":"w1"}],"agents":[],"workspaces":[],"tabs":[]}}}
            """
        let agents = HerdrListParser.agents(
            fromSnapshot: json, session: "default", machineID: "local", machineName: "This Mac",
            machineIsLocal: true, sshTarget: nil)
        #expect(agents.count == 1)
        #expect(agents[0].title == "w1:pA")
        #expect(agents[0].processLabel == HerdrKind.terminalLabel)
    }

    @Test func aKnownAgentIsNeverDemotedToATerminal() {
        let cache = HerdrBoardCache(context: context)
        cache.applySnapshot(snapshot)
        let hollow = """
            {"id":"s","result":{"type":"session_snapshot","snapshot":{"panes":[{"pane_id":"w2:p1","agent_status":"unknown","tab_id":"w2:t1","workspace_id":"w2"}],"agents":[],"workspaces":[],"tabs":[]}}}
            """
        let kept = cache.applySnapshot(hollow)
        #expect(kept.map(\.pane) == ["w2:p1"])
        #expect(kept[0].category == .agent)
        #expect(kept[0].kind == "Claude Code")
    }

    @Test func processNamesLandOnTerminalsOnly() {
        let cache = HerdrBoardCache(context: context)
        cache.applySnapshot(snapshot)
        #expect(cache.terminalPanes == ["w2:p6"])
        let updated = cache.applyProcessNames(["w2:p6": "bun", "w2:p1": "claude"])
        #expect(updated.first { $0.pane == "w2:p6" }?.process == "bun")
        #expect(updated.first { $0.pane == "w2:p6" }?.processLabel == "bun")
    }

    @Test func processNameReadsTheForegroundProcess() {
        let payload = """
            {"id":"cli:pane:process_info","result":{"process_info":{"foreground_processes":[{"argv0":"zsh","name":"zsh"},{"argv0":"bun","name":"bun"}],"pane_id":"w2:p6"},"type":"pane_process_info"}}
            """
        #expect(HerdrListParser.processName(in: payload) == "bun")
    }

    @Test func aLoginShellLosesItsLeadingDash() {
        let payload = """
            {"id":"cli:pane:process_info","result":{"process_info":{"foreground_processes":[{"argv0":"-zsh","name":"-zsh"}],"pane_id":"w1:pA"},"type":"pane_process_info"}}
            """
        #expect(HerdrListParser.processName(in: payload) == "zsh")
    }

    @Test func oneCommandAsksForEveryTerminalProcess() {
        let command = HerdrCollector.processInfoCommand(
            session: "default", panes: ["w1:pA", "w2:p7"])
        #expect(command.contains("for pane in w1:pA w2:p7"))
        #expect(command.contains("herdr --session default pane process-info --pane"))
        let risky = HerdrCollector.processInfoCommand(session: "a b", panes: ["x; rm -rf /"])
        #expect(risky.contains("'x; rm -rf /'"))
    }

    @Test func processNamesAreReadPerPaneFromABatch() {
        let batch = """
            {"id":"a","result":{"process_info":{"foreground_processes":[{"name":"bun"}],"pane_id":"w2:p6"},"type":"pane_process_info"}}
            {"id":"b","result":{"process_info":{"foreground_processes":[{"name":"-zsh"}],"pane_id":"w1:pA"},"type":"pane_process_info"}}
            """
        let names = HerdrListParser.processNames(in: batch)
        #expect(names == ["w2:p6": "bun", "w1:pA": "zsh"])
    }

    @Test func aNumberedTabNeverBecomesATerminalTitle() {
        let json = """
            {"id":"s","result":{"type":"session_snapshot","snapshot":{"panes":[{"pane_id":"w1:pA","agent_status":"unknown","tab_id":"w1:tA","workspace_id":"w1"}],"agents":[],"workspaces":[],"tabs":[{"tab_id":"w1:tA","label":"2","workspace_id":"w1"}]}}}
            """
        let agents = HerdrListParser.agents(
            fromSnapshot: json, session: "default", machineID: "local", machineName: "This Mac",
            machineIsLocal: true, sshTarget: nil)
        #expect(agents[0].title == "w1:pA")
    }

    @Test func everyTerminalIsAskedOnceAndFailuresAreSkipped() async {
        var asked: [String] = []
        let names = await HerdrLive.processNames(panes: ["w2:p6", "w1:pA", "w9:pZ"]) { pane in
            asked.append(pane)
            switch pane {
            case "w2:p6":
                return """
                    {"id":"p","result":{"process_info":{"foreground_processes":[{"name":"bun"}],"pane_id":"w2:p6"},"type":"pane_process_info"}}
                    """
            case "w1:pA":
                return nil
            default:
                return "not json at all"
            }
        }
        #expect(asked == ["w2:p6", "w1:pA", "w9:pZ"])
        #expect(names == ["w2:p6": "bun"])
    }

    @Test func aNumberedTabIsNeverATitleEvenWhenTheTabIsRenamed() {
        let cache = HerdrBoardCache(context: context)
        cache.applySnapshot(snapshot)
        let renamed = cache.applyEvent(
            """
            {"event":"tab.renamed","data":{"tab":{"tab_id":"w2:t6","label":"7"}}}
            """)
        #expect(renamed.first { $0.pane == "w2:p6" }?.title == "site dev server")
        let named = cache.applyEvent(
            """
            {"event":"tab.renamed","data":{"tab":{"tab_id":"w2:t6","label":"api watch"}}}
            """)
        #expect(named.first { $0.pane == "w2:p6" }?.title == "api watch")
    }

    @Test func aSnapshotDropsPanesThatAreNoLongerThere() {
        let cache = HerdrBoardCache(context: context)
        cache.applySnapshot(snapshot)
        cache.applyEvent(
            """
            {"event":"pane.created","data":{"pane":{"pane_id":"w2:p9","agent_status":"unknown","tab_id":"w2:t9","workspace_id":"w2"}}}
            """)
        #expect(cache.agents.map(\.pane).contains("w2:p9"))
        let reconciled = cache.applySnapshot(snapshot)
        #expect(!reconciled.map(\.pane).contains("w2:p9"))
        #expect(reconciled.map(\.pane) == ["w2:p1", "w2:p6"])
    }

    @Test func onlyTerminalsMissingANameAreLookedUp() {
        let cache = HerdrBoardCache(context: context)
        cache.applySnapshot(snapshot)
        #expect(cache.unnamedTerminalPanes == ["w2:p6"])
        cache.applyProcessNames(["w2:p6": "bun"])
        #expect(cache.unnamedTerminalPanes.isEmpty)
        #expect(cache.terminalPanes == ["w2:p6"])
    }

    @Test func createdPaneIsReadFromTheRootPane() {
        let payload = """
            {"id":"cli:tab:create","result":{"root_pane":{"pane_id":"w2:p7","tab_id":"w2:t7","workspace_id":"w2"},"tab":{"label":"probe","tab_id":"w2:t7"},"type":"tab_created"}}
            """
        #expect(HerdrListParser.createdPane(in: payload) == "w2:p7")
    }

    @Test func creationArgumentsCarryOnlyTheFieldsThatWereGiven() {
        let bare = HerdrTerminalOperationExecution.arguments(
            for: HerdrTerminalRequest(session: "default"))
        #expect(bare == ["--session", "default", "tab", "create", "--no-focus"])
        let full = HerdrTerminalOperationExecution.arguments(
            for: HerdrTerminalRequest(
                session: "work", workspace: "w2", cwd: "/repo", label: "site dev server"))
        #expect(
            full == [
                "--session", "work", "tab", "create", "--no-focus", "--workspace", "w2",
                "--cwd", "/repo", "--label", "site dev server",
            ])
    }

    @Test func blankFieldsAreTreatedAsAbsent() {
        let arguments = HerdrTerminalOperationExecution.arguments(
            for: HerdrTerminalRequest(session: "default", workspace: "  ", cwd: "", label: " "))
        #expect(arguments == ["--session", "default", "tab", "create", "--no-focus"])
    }

    @Test func theShellLineQuotesEveryArgument() {
        let line = HerdrTerminalOperationExecution.shellLine(
            for: HerdrTerminalRequest(session: "default", label: "site dev server"))
        #expect(line.contains("'site dev server'"))
        #expect(
            HerdrTerminalOperationExecution.remoteShellLine(for: .init()).hasPrefix("export PATH="))
    }

    @Test func aTerminalAttachesWithTheHerdrClient() {
        let local = terminal(machineIsLocal: true, sshTarget: nil)
        #expect(HerdrAttachCommand.line(for: local) == "herdr --session default")
        let remote = terminal(machineIsLocal: false, sshTarget: "tuf-wired")
        #expect(
            HerdrAttachCommand.line(for: remote) == "herdr --remote tuf-wired --session default")
    }

    @Test func anAgentStillAttachesToItsOwnPane() {
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p1", kind: "Claude Code", status: .working,
            title: "Work", workspace: "edith", cwd: "/repo")
        #expect(HerdrAttachCommand.line(for: agent) == "herdr --session default agent attach w2:p1")
    }

    @Test func theRemoteClientRunsLocallyAndDialsTheMachineItself() {
        let request = HerdrTerminalOperationExecution.remoteClientRequest(
            for: terminal(machineIsLocal: false, sshTarget: "tuf-wired"), target: "tuf-wired",
            environment: [], executable: URL(fileURLWithPath: "/usr/local/bin/herdr"))
        #expect(request.executable == "/usr/local/bin/herdr")
        #expect(request.arguments == ["--remote", "tuf-wired", "--session", "default"])
    }

    @Test func focusRunsBeforeTheClientAttaches() {
        let line = HerdrTerminalOperationExecution.focusShellLine(
            session: "default", pane: "w2:p6")
        #expect(line.contains("pane focus"))
        #expect(line.contains("w2:p6"))
    }

    @Test func splitFractionsAreClampedAndKeptPerPane() {
        let store = UserDefaults(suiteName: "herdr.split.\(UUID().uuidString)")!
        #expect(HerdrSplitFraction.fraction(for: "a", store) == HerdrSplitFraction.standard)
        HerdrSplitFraction.set(0.95, for: "a", store)
        #expect(HerdrSplitFraction.fraction(for: "a", store) == HerdrSplitFraction.maximum)
        HerdrSplitFraction.set(0.01, for: "b", store)
        #expect(HerdrSplitFraction.fraction(for: "b", store) == HerdrSplitFraction.minimum)
        HerdrSplitFraction.set(0.5, for: "a", store)
        #expect(HerdrSplitFraction.fraction(for: "a", store) == 0.5)
        #expect(HerdrSplitFraction.fraction(for: "b", store) == HerdrSplitFraction.minimum)
    }

    @Test func splitShowsBothPanesAndTheOthersShowOne() {
        #expect(HerdrAgentView.split.showsAgent)
        #expect(HerdrAgentView.split.showsDiff)
        #expect(HerdrAgentView.agent.showsAgent)
        #expect(!HerdrAgentView.agent.showsDiff)
        #expect(!HerdrAgentView.diff.showsAgent)
        #expect(HerdrAgentView.diff.showsDiff)
    }

    @Test func theStoredViewSurvivesARoundTrip() {
        let store = UserDefaults(suiteName: "herdr.view.\(UUID().uuidString)")!
        HerdrAgentViews.set(.split, for: "pane", store)
        #expect(HerdrAgentViews.view(for: "pane", store) == .split)
        HerdrAgentViews.set(.agent, for: "pane", store)
        #expect(HerdrAgentViews.view(for: "pane", store) == .agent)
    }

    private func terminal(machineIsLocal: Bool, sshTarget: String?) -> HerdrAgent {
        HerdrAgent.make(
            machineID: machineIsLocal ? "local" : "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB",
            machineName: machineIsLocal ? "This Mac" : "tuf-wired",
            machineIsLocal: machineIsLocal, sshTarget: sshTarget, session: "default",
            pane: "w2:p6", kind: HerdrKind.terminalLabel, status: .unknown,
            title: "site dev server", workspace: "edith", cwd: "/repo/apps/site",
            category: .terminal, process: "bun")
    }

    private let context = HerdrBoardContext(
        session: "default", machineID: "local", machineName: "This Mac", machineIsLocal: true,
        sshTarget: nil)

    private let snapshot = """
        {"id":"s","result":{"type":"session_snapshot","snapshot":{"panes":[{"pane_id":"w2:p1","agent":"claude","agent_status":"working","terminal_title_stripped":"Herdr cockpit","tab_id":"w2:t1","workspace_id":"w2","foreground_cwd":"/repo"},{"pane_id":"w2:p6","agent_status":"unknown","tab_id":"w2:t6","workspace_id":"w2","foreground_cwd":"/repo/apps/site"}],"agents":[{"pane_id":"w2:p1","agent":"claude","agent_status":"working","tab_id":"w2:t1","workspace_id":"w2"}],"workspaces":[{"label":"edith","workspace_id":"w2"}],"tabs":[{"tab_id":"w2:t1","label":"1","workspace_id":"w2"},{"tab_id":"w2:t6","label":"site dev server","workspace_id":"w2"}]}}}
        """
}
