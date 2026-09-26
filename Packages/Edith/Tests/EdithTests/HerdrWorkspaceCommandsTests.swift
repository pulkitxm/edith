import Foundation
import Testing

@testable import EdithKit

@Suite struct HerdrWorkspaceCommandsTests {
    @Test func workspaceCreateOmitsCwdWhenNotGiven() {
        #expect(
            HerdrWorkspaceCreateCommand.arguments(label: "my-space", cwd: nil)
                == ["workspace", "create", "--label", "my-space", "--no-focus"])
    }

    @Test func workspaceCreateIncludesCwdWhenGiven() {
        #expect(
            HerdrWorkspaceCreateCommand.arguments(label: "my-space", cwd: "/tmp/project")
                == [
                    "workspace", "create", "--label", "my-space", "--no-focus", "--cwd",
                    "/tmp/project",
                ])
    }

    @Test func tabCreateTargetsAWorkspace() {
        #expect(
            HerdrTabCreateCommand.arguments(workspaceID: "w5", cwd: nil)
                == ["tab", "create", "--workspace", "w5", "--no-focus"])
    }

    @Test func workspaceListTakesNoArguments() {
        #expect(HerdrWorkspaceListCommand.arguments == ["workspace", "list"])
    }

    @Test func agentStartNameLowercasesPublicIds() {
        #expect(HerdrAgentStartCommand.name("grok", pane: "w5:p1") == "grok-w5-p1")
        #expect(HerdrAgentStartCommand.name("grok", pane: "w5:p1V") == "grok-w5-p1v")
        #expect(HerdrAgentStartCommand.name("grok", pane: "wG:pA") == "grok-wg-pa")
    }

    @Test func agentStartCarriesKindPaneAndTimeout() {
        #expect(
            HerdrAgentStartCommand.arguments(
                name: "claude", kindSlug: "claude", pane: "w5:p1", timeoutMS: 30_000)
                == [
                    "agent", "start", "claude", "--kind", "claude", "--pane", "w5:p1", "--timeout",
                    "30000",
                ])
    }

    @Test func paneRunSendsTheLiteralCommandText() {
        #expect(
            HerdrPaneRunCommand.arguments(pane: "w5:p1", command: "CC")
                == ["pane", "run", "w5:p1", "CC"])
    }

    @Test func shellLinesPrefixHerdrAndQuoteEachArgument() {
        let line = HerdrWorkspaceCreateCommand.shellLine(
            label: "my space", cwd: nil, platform: .linux)
        #expect(line.contains("herdr"))
        #expect(line.contains("'my space'"))
    }

    @Test func windowsShellLinesUsePowerShell() {
        let line = HerdrPaneRunCommand.shellLine(
            pane: "w5:p1", command: "CC", platform: .windows)
        #expect(line.contains("powershell.exe"))
        #expect(line.contains("-EncodedCommand"))
    }
}
