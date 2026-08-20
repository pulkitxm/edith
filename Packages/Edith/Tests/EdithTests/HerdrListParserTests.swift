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

    @Test func sessionListReadsSocketPathsAndRunningFlags() {
        let json = """
            {"sessions":[{"default":true,"name":"default","running":true,"session_dir":"/Users/me/.config/herdr","socket_path":"/Users/me/.config/herdr/herdr.sock"},{"name":"work","running":false,"socket_path":"/Users/me/.config/herdr/sessions/work/herdr.sock"}]}
            """
        let records = HerdrListParser.sessionRecords(from: json)
        #expect(records.map(\.name) == ["default", "work"])
        #expect(records[0].running)
        #expect(records[0].socketPath == "/Users/me/.config/herdr/herdr.sock")
        #expect(!records[1].running)
        #expect(HerdrListParser.sessions(from: json) == ["default", "work"])
    }

    @Test func snapshotMapsWorkspaceLabelsAndStrippedTitles() {
        let json = """
            {"id":"s","result":{"type":"session_snapshot","snapshot":{"agents":[{"agent":"cursor","agent_status":"idle","cwd":"/repo","foreground_cwd":"/repo/app","pane_id":"w1:p8","tab_id":"w1:t8","terminal_title_stripped":"Nextjs Explainer","workspace_id":"w1"}],"workspaces":[{"label":"Edith","workspace_id":"w1"}]}}}
            """
        #expect(HerdrListParser.hasSnapshot(json))
        let agents = HerdrListParser.agents(
            fromSnapshot: json, session: "default", machineID: "local", machineName: "This Mac",
            machineIsLocal: true, sshTarget: nil)
        #expect(agents.count == 1)
        #expect(agents[0].kind == "Cursor Agent")
        #expect(agents[0].status == .idle)
        #expect(agents[0].title == "Nextjs Explainer")
        #expect(agents[0].workspace == "Edith")
        #expect(agents[0].cwd == "/repo/app")
        #expect(agents[0].pane == "w1:p8")
    }

    @Test func snapshotUnionsPanesWhenAgentsDropsTheRow() {
        let json = """
            {"id":"s","result":{"type":"session_snapshot","snapshot":{"panes":[{"pane_id":"w3:p1N","agent":"opencode","agent_status":"working","terminal_title_stripped":"Image Query","workspace_id":"w3","foreground_cwd":"/srv/app"},{"pane_id":"w3:p1Q","agent":null,"agent_status":"unknown","workspace_id":"w3"}],"agents":[],"workspaces":[{"label":"quinjet","workspace_id":"w3"}]}}}
            """
        let agents = HerdrListParser.agents(
            fromSnapshot: json, session: "default",
            machineID: "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB", machineName: "tuf-wired",
            machineIsLocal: false, sshTarget: "tuf-wired")
        #expect(agents.map(\.pane) == ["w3:p1N"])
        #expect(agents[0].kind == "OpenCode")
        #expect(agents[0].status == .working)
        #expect(agents[0].workspace == "quinjet")
        #expect(agents[0].id == "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB|default|w3:p1N")
    }

    @Test func eventNameNormalizesDottedTypes() {
        #expect(
            HerdrListParser.eventName(
                in:
                    #"{"event":"pane.updated","data":{"type":"pane.updated","pane":{"pane_id":"w3:p1N"}}}"#
            ) == "pane_updated")
        #expect(
            HerdrListParser.eventName(
                in:
                    #"{"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"w3:p1N"}}}"#
            ) == "pane_updated")
        #expect(
            HerdrListParser.eventReleased(
                in:
                    #"{"event":"pane_agent_detected","data":{"released":true,"pane_id":"w3:p1N"}}"#)
        )
        #expect(
            HerdrListParser.eventFinalStatus(
                in:
                    #"{"event":"pane_agent_detected","data":{"released":true,"final_status":"idle","pane_id":"w3:p1N"}}"#
            ) == "idle")
        #expect(
            !HerdrListParser.eventReleased(
                in: #"{"event":"pane_agent_detected","data":{"agent":"cursor","pane_id":"w3:p1N"}}"#
            ))
    }

    @Test func eventLinesAreDistinctFromRpcReplies() {
        #expect(
            HerdrListParser.isEventLine(
                #"{"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"w1:p8"}}}"#
            ))
        #expect(
            !HerdrListParser.isEventLine(#"{"id":"sub1","result":{"type":"subscription_started"}}"#)
        )
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

@Suite struct HerdrKindTests {
    @Test func displayNamesCoverTheCommonAgents() {
        #expect(HerdrKind.displayName(for: "opencode") == "OpenCode")
        #expect(HerdrKind.displayName(for: "claude-code") == "Claude Code")
        #expect(HerdrKind.displayName(for: "codex") == "Codex")
        #expect(HerdrKind.displayName(for: "pi") == "Pi")
        #expect(HerdrKind.displayName(for: "py") == "Pi")
        #expect(HerdrKind.displayName(for: "cursor-agent") == "Cursor Agent")
        #expect(HerdrKind.displayName(for: "gemini") == "Gemini")
        #expect(HerdrKind.displayName(for: "grok") == "Grok")
        #expect(HerdrKind.displayName(for: "cline") == "Cline")
    }

    @Test func logoNamesPointAtKitResources() {
        #expect(HerdrKind.logoName(for: "Claude Code") == "claude")
        #expect(HerdrKind.logoName(for: "Codex") == "codex")
        #expect(HerdrKind.logoName(for: "OpenCode") == "opencode")
        #expect(HerdrKind.logoName(for: "pi") == "pi")
        #expect(HerdrKind.logoName(for: "Cursor Agent") == "cursor")
        #expect(HerdrKind.logoName(for: "Copilot CLI") == "copilot")
        #expect(HerdrKind.logoName(for: "Gemini") == "gemini")
        #expect(HerdrKind.logoName(for: "Grok") == "grok")
        #expect(HerdrKind.logoName(for: "Cline") == "cline")
        #expect(HerdrKind.logoName(for: "Amp") == "amp")
        #expect(HerdrKind.logoName(for: "Devin") == "devin")
        #expect(HerdrKind.logoName(for: "Kimi") == "kimi")
        #expect(HerdrKind.monogram(for: "OMP") == "O")
        #expect(HerdrKind.logoName(for: "OMP") == nil)
    }

    @Test func kitBundleContainsTheAgentMarks() {
        for name in [
            "claude", "codex", "opencode", "cursor", "copilot", "pi", "gemini", "grok", "cline",
            "amp", "antigravity", "devin", "kilo", "kimi", "kiro", "mastra", "qoder", "qwen",
        ] {
            #expect(ProviderLogo.image(named: name) != nil, "missing \(name).svg")
        }
    }

    @Test func officialHerdrMarkIsInTheKitBundle() {
        #expect(ProviderLogo.image(named: "herdr") != nil)
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

@Suite struct HerdrSocketDiscoveryTests {
    @Test func sessionNameFromDefaultAndNamedSockets() {
        #expect(
            HerdrSocketDiscovery.sessionName(for: "/Users/me/.config/herdr/herdr.sock") == "default"
        )
        #expect(
            HerdrSocketDiscovery.sessionName(
                for: "/home/me/.config/herdr/sessions/work/herdr.sock") == "work")
    }

    @Test func remoteListingKeepsUnixSockets() {
        let text = """
            /home/me/.config/herdr/herdr.sock
            /home/me/.config/herdr/sessions/lab/herdr.sock
            """
        let sockets = HerdrSocketDiscovery.sockets(fromRemoteListing: text)
        #expect(sockets.map(\.name) == ["default", "lab"])
        #expect(sockets.map(\.path).count == 2)
    }

    @Test func relayScriptTalksUnixSockets() {
        #expect(HerdrSocketClient.relayScript.contains("AF_UNIX"))
        #expect(HerdrSocketClient.boardSubscriptions.contains { $0["type"] == "pane.updated" })
    }

    @Test func aMissingSocketThrowsInsteadOfAborting() {
        #expect(throws: HerdrSocketError.self) {
            try HerdrSocketClient.unix(path: "/tmp/edith-herdr-missing.sock")
        }
    }

    @Test func closingALiveSocketDoesNotAbort() throws {
        guard let path = HerdrSocketDiscovery.local().first?.path else { return }
        let client = try HerdrSocketClient.unix(path: path)
        client.close()
    }
}
