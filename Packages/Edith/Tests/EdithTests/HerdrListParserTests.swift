import Foundation
import Testing

@testable import EdithKit

@Suite struct HerdrListParserTests {
    @Test func unwrapsTheEnvelopeAndReadsBlockedWorkingPanes() {
        let json = """
            {
              "ok": true,
              "result": {
                "agents": [
                  {
                    "pane_id": "w3:p1N",
                    "agent": "opencode",
                    "agent_status": "working",
                    "title": "Build the Herdr board",
                    "workspace_id": "edith",
                    "cwd": "/Users/pulkit/Desktop/Edith"
                  },
                  {
                    "pane": "w3:p1Q",
                    "kind": "claude-code",
                    "status": "blocked",
                    "name": "Waiting on a key",
                    "workspace": "quinjet"
                  }
                ]
              }
            }
            """
        let agents = HerdrListParser.agents(
            from: json, session: "default", machineID: "local", machineName: "This Mac",
            machineIsLocal: true, sshTarget: nil)
        #expect(agents.count == 2)
        #expect(agents[0].pane == "w3:p1N")
        #expect(agents[0].kind == "OpenCode")
        #expect(agents[0].status == .working)
        #expect(agents[0].title == "Build the Herdr board")
        #expect(agents[0].workspace == "edith")
        #expect(agents[0].id == "local|default|w3:p1N")
        #expect(agents[1].kind == "Claude Code")
        #expect(agents[1].status == .blocked)
        #expect(agents[1].title == "Waiting on a key")
    }

    @Test func readsABareArrayWithAlternateFieldNames() {
        let json = """
            [
              {
                "id": "w3:p1T",
                "display_agent": "Cursor Agent CLI",
                "state": "idle",
                "terminal_title_stripped": "Image Query",
                "working_directory": "/srv/app"
              }
            ]
            """
        let agents = HerdrListParser.agents(
            from: json, session: "work", machineID: "abc", machineName: "Asus TUF 7",
            machineIsLocal: false, sshTarget: "tuf-wired")
        #expect(agents.count == 1)
        #expect(agents[0].pane == "w3:p1T")
        #expect(agents[0].kind == "Cursor Agent")
        #expect(agents[0].status == .idle)
        #expect(agents[0].title == "Image Query")
        #expect(agents[0].cwd == "/srv/app")
        #expect(agents[0].machineIsLocal == false)
        #expect(agents[0].sshTarget == "tuf-wired")
        #expect(agents[0].id == "abc|work|w3:p1T")
    }

    @Test func sessionListReadsNamesFromTheEnvelope() {
        let json = """
            {"ok":true,"result":{"sessions":[{"name":"default"},{"name":"work"}]}}
            """
        #expect(HerdrListParser.sessions(from: json) == ["default", "work"])
    }

    @Test func sessionListReadsAStringArray() {
        #expect(HerdrListParser.sessions(from: #"["default","lab"]"#) == ["default", "lab"])
    }

    @Test func garbageIsAnEmptyList() {
        #expect(
            HerdrListParser.agents(
                from: "herdr: command not found", session: "default", machineID: "local",
                machineName: "This Mac", machineIsLocal: true, sshTarget: nil
            ).isEmpty)
        #expect(HerdrListParser.sessions(from: "not json").isEmpty)
    }

    @Test func jsonErrorObjectsSurfaceTheServerMessage() {
        let json = """
            {"id":"cli:agent:list","error":{"code":"server_not_running","message":"no herdr server is running"}}
            """
        #expect(HerdrListParser.errorMessage(in: json) == "no herdr server is running")
        #expect(
            HerdrListParser.agents(
                from: json, session: "default", machineID: "local", machineName: "This Mac",
                machineIsLocal: true, sshTarget: nil
            ).isEmpty)
    }

    @Test func statusAliasesMapOntoTheBoardColumns() {
        #expect(HerdrAgentStatus.parse("needs_attention") == .blocked)
        #expect(HerdrAgentStatus.parse("running") == .working)
        #expect(HerdrAgentStatus.parse("completed") == .done)
        #expect(HerdrAgentStatus.parse("ready") == .idle)
        #expect(HerdrAgentStatus.parse("something-else") == .unknown)
    }
}

@Suite struct HerdrAttachCommandTests {
    @Test func localAttachIsTheHerdrLine() {
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w3:p1N", kind: "OpenCode", status: .working,
            title: "Board", workspace: "edith", cwd: "/tmp")
        #expect(
            HerdrAttachCommand.line(for: agent) == "herdr --session default agent attach w3:p1N")
    }

    @Test func remoteAttachIsAnSSHCommand() {
        let agent = HerdrAgent.make(
            machineID: "tuf", machineName: "Asus TUF 7", machineIsLocal: false,
            sshTarget: "tuf-wired", session: "default", pane: "w3:p1N", kind: "OpenCode",
            status: .working, title: "Board", workspace: "edith", cwd: "/tmp")
        #expect(
            HerdrAttachCommand.line(for: agent)
                == "ssh -tt tuf-wired -- herdr --session default agent attach w3:p1N")
    }
}
