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

    @Test func WindowsMachineTerminalRunsHerdrOnTheRemoteHost() {
        let machine = Machine(name: "Box", host: "box.example", username: "dev")
        let connection = SSHConnection(machine: machine)
        let request = HerdrMachineTerminal.windowsLaunchRequest(
            connection: connection, environment: ["TERM=xterm-256color", "HERDR_ENV=1"])

        #expect(request.executable == SSHConnection.executable.path)
        #expect(request.arguments.contains("-tt"))
        #expect(request.arguments.last?.hasPrefix("powershell.exe ") == true)
        #expect(request.arguments.last?.contains("--remote") == false)
        #expect(request.environment.contains("HERDR_ENV="))
        #expect(!request.environment.contains("HERDR_ENV=1"))
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

    @Test func agentControllerUsesTheRawTerminalSessionProtocol() throws {
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "work session", pane: "w2:p1", kind: "OpenCode", status: .working,
            title: "Work", workspace: "edith", cwd: "/repo")
        let controller = HerdrOperationExecution.localControlRequest(
            for: agent, environment: ["TERM=xterm-256color"],
            executable: URL(fileURLWithPath: "/usr/local/bin/herdr"))

        #expect(controller.executable == "/usr/local/bin/herdr")
        #expect(
            controller.arguments == [
                "--session", "work session", "terminal", "session", "control", "w2:p1",
                "--takeover", "--cols", "{columns}", "--rows", "{rows}",
            ])

        let specification = HerdrTerminalBridgeSpecification(controller: controller)
        let decoded = try HerdrTerminalBridgeSpecification(encoded: specification.encoded())
        #expect(decoded == specification)
        #expect(
            decoded.request(columns: 144, rows: 52).arguments.suffix(4) == [
                "--cols", "144", "--rows", "52",
            ])
    }

    @Test func bridgeReplacesDimensionsInsideEncodedPowerShell() throws {
        let command = PowerShell.command(
            "$cols = '{columns}'; $rows = '{rows}'; Write-Output \"$cols x $rows\"")
        let controller = TerminalLaunchRequest(
            executable: "/usr/bin/ssh", arguments: ["win-lan", command], environment: [])

        let request = HerdrTerminalBridgeSpecification(controller: controller)
            .request(columns: 132, rows: 48)
        let encoded = try #require(request.arguments.last?.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))

        #expect(
            String(data: data, encoding: .utf16LittleEndian)
                == "$cols = '132'; $rows = '48'; Write-Output \"$cols x $rows\"")
    }

    @Test func embeddedBridgeLaunchesTheBundledCommand() throws {
        let controller = TerminalLaunchRequest(
            executable: "/usr/local/bin/herdr",
            arguments: ["terminal", "session", "control", "w2:p1"],
            environment: ["TERM=xterm-256color"])
        let request = try HerdrTerminalBridge.launchRequest(
            bridgeExecutable: URL(fileURLWithPath: "/Applications/Edith.app/Contents/MacOS/ed"),
            controller: controller)

        #expect(request.executable == "/Applications/Edith.app/Contents/MacOS/ed")
        #expect(request.arguments.prefix(2) == ["herdr", "bridge"])
        #expect(request.environment == controller.environment)
        let decoded = try HerdrTerminalBridgeSpecification(encoded: request.arguments[2])
        #expect(decoded == HerdrTerminalBridgeSpecification(controller: controller))
    }

    @Test func bridgeProtocolForwardsFramesAndInputBytes() throws {
        let bytes = Data([0x1B, 0x5B, 0x3C, 0x30, 0x3B, 0x31, 0x3B, 0x31, 0x4D])
        let frame = try JSONSerialization.data(withJSONObject: [
            "type": "terminal.frame", "bytes": bytes.base64EncodedString(),
        ])
        #expect(try HerdrTerminalBridge.decodeRecord(frame) == .frame(bytes))

        let input = try HerdrTerminalBridge.inputCommand(bytes)
        let object = try #require(
            JSONSerialization.jsonObject(with: input) as? [String: String])
        #expect(object["type"] == "terminal.input")
        #expect(object["bytes"] == bytes.base64EncodedString())
    }

    @Test func bridgeProtocolEncodesWheelScrolls() throws {
        let command = try HerdrTerminalBridge.scrollCommand(
            direction: .down, lines: 3, column: 10, row: 5, modifiers: 7)
        let object = try #require(
            JSONSerialization.jsonObject(with: command) as? [String: Any])
        #expect(object["type"] as? String == "terminal.scroll")
        #expect(object["direction"] as? String == "down")
        #expect(object["source"] as? String == "wheel")
        #expect(object["lines"] as? Int == 3)
        #expect(object["column"] as? Int == 10)
        #expect(object["row"] as? Int == 5)
        #expect(object["modifiers"] as? Int == 7)
    }

    @Test func bridgeEnablesHoverAndButtonMouseReporting() {
        let start = String(decoding: HerdrTerminalBridge.startSequence, as: UTF8.self)
        let stop = String(decoding: HerdrTerminalBridge.stopSequence, as: UTF8.self)
        for mode in ["1000", "1002", "1003", "1006"] {
            #expect(start.contains("\u{1B}[?\(mode)h"))
            #expect(stop.contains("\u{1B}[?\(mode)l"))
        }
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
