import Foundation
import Testing

@testable import EdithKit

@Suite struct HerdrTerminalTests {
    @Test func everyHostWithHerdrOffersOneTerminal() {
        let local = HerdrMachineTerminal.agent(for: .local(herdrPresent: true))
        #expect(local.isTerminal)
        #expect(local.category == .terminal)
        #expect(local.title == HerdrMachineTerminal.title)
        #expect(local.machineName == "This Mac")
        #expect(local.id == "local|terminal")
        #expect(local.pane.isEmpty)
        #expect(local.session.isEmpty)
    }

    @Test func theLocalTerminalJustRunsHerdr() {
        let local = HerdrMachineTerminal.agent(for: .local(herdrPresent: true))
        #expect(HerdrMachineTerminal.arguments(for: local).isEmpty)
        #expect(HerdrMachineTerminal.line(for: local) == "herdr")
        #expect(HerdrAttachCommand.line(for: local) == "herdr")
    }

    @Test func aMachineTerminalDialsThatMachineItself() {
        let remote = HerdrMachineTerminal.agent(for: host)
        #expect(HerdrMachineTerminal.arguments(for: remote) == ["--remote", "tuf-wired"])
        #expect(HerdrMachineTerminal.line(for: remote) == "herdr --remote tuf-wired")
        #expect(HerdrAttachCommand.line(for: remote) == "herdr --remote tuf-wired")
        #expect(remote.id == "\(host.id)|terminal")
    }

    @Test func theClientRunsLocallyEvenForAnotherMachine() {
        let remote = HerdrMachineTerminal.agent(for: host)
        let request = HerdrMachineTerminal.launchRequest(
            for: remote, environment: ["TERM=xterm-256color"],
            executable: URL(fileURLWithPath: "/usr/local/bin/herdr"))
        #expect(request.executable == "/usr/local/bin/herdr")
        #expect(request.arguments == ["--remote", "tuf-wired"])
        #expect(request.environment.contains("TERM=xterm-256color"))
    }

    @Test func aMissingBinaryFallsBackToALoginShell() {
        let remote = HerdrMachineTerminal.agent(for: host)
        let request = HerdrMachineTerminal.launchRequest(
            for: remote, environment: [], executable: nil)
        #expect(request.executable == "/bin/zsh")
        #expect(request.arguments.first == "-c")
        #expect(request.arguments.last?.contains("herdr --remote tuf-wired") == true)
        #expect(request.arguments.last?.hasPrefix("export PATH=") == true)
    }

    @Test func aTerminalStartedInsideHerdrDoesNotLookNested() {
        let environment = [
            "TERM=xterm-256color", "HERDR_ENV=1", "HERDR_PANE_ID=w2:pG",
            "HERDR_SOCKET_PATH=/tmp/herdr.sock", "HERDR_TAB_ID=w2:tG",
            "HERDR_WORKSPACE_ID=w2", "PATH=/usr/bin",
        ]
        let clean = HerdrMachineTerminal.unnested(environment)
        #expect(clean.contains("TERM=xterm-256color"))
        #expect(clean.contains("PATH=/usr/bin"))
        #expect(!clean.contains("HERDR_ENV=1"))
        #expect(!clean.contains("HERDR_PANE_ID=w2:pG"))
        #expect(clean.contains("HERDR_SOCKET_PATH=/tmp/herdr.sock"))
        for name in HerdrMachineTerminal.nestingVariables {
            #expect(clean.contains("\(name)="))
        }
    }

    @Test func theLaunchRequestCarriesTheClearedEnvironment() {
        let local = HerdrMachineTerminal.agent(for: .local(herdrPresent: true))
        let request = HerdrMachineTerminal.launchRequest(
            for: local, environment: ["HERDR_ENV=1", "TERM=xterm-256color"],
            executable: URL(fileURLWithPath: "/usr/local/bin/herdr"))
        #expect(!request.environment.contains("HERDR_ENV=1"))
        #expect(request.environment.contains("HERDR_ENV="))
        #expect(request.environment.contains("TERM=xterm-256color"))
    }

    @Test func anAgentStillAttachesToItsOwnPane() {
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p1", kind: "Claude Code", status: .working,
            title: "Work", workspace: "edith", cwd: "/repo")
        #expect(!agent.isTerminal)
        #expect(
            HerdrAttachCommand.line(for: agent)
                == "herdr --session default agent attach w2:p1 --takeover")
    }

    @Test func closingAnAgentInterruptsItWithoutClosingItsPane() {
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "work session", pane: "w2:p1", kind: "Claude Code", status: .working,
            title: "Work", workspace: "edith", cwd: "/repo")
        #expect(
            HerdrAgentCloseCommand.arguments(for: agent) == [
                "--session", "work session", "agent", "send-keys", "w2:p1", "ctrl+c", "ctrl+c",
            ])
        let line = HerdrAgentCloseCommand.shellLine(for: agent)
        #expect(line.contains("agent send-keys"))
        #expect(line.contains("ctrl+c ctrl+c"))
        #expect(!line.contains("pane close"))
    }

    @Test func aPlainPaneIsNotListedAsAnAgent() {
        let json = """
            {"id":"s","result":{"type":"session_snapshot","snapshot":{"panes":[{"pane_id":"w2:p1","agent":"claude","agent_status":"working","terminal_title_stripped":"Work","workspace_id":"w2"},{"pane_id":"w1:pA","agent_status":"unknown","workspace_id":"w1"}],"agents":[],"workspaces":[]}}}
            """
        let agents = HerdrListParser.agents(
            fromSnapshot: json, session: "default", machineID: "local", machineName: "This Mac",
            machineIsLocal: true, sshTarget: nil)
        #expect(agents.map(\.pane) == ["w2:p1"])
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

    private let host = HerdrHostSnapshot(
        id: "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB", name: "tuf-wired", isLocal: false,
        sshTarget: "tuf-wired", herdrPresent: true, reachable: true)
}
