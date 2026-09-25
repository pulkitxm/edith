import EdithCore
import Foundation
import MCP
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct OperationMCPTests {
    @Test func everyRouteBecomesOneUniquelyNamedTool() {
        let tools = OperationMCPCatalog.tools
        #expect(!tools.isEmpty)
        #expect(Set(tools.map(\.name)).count == tools.count)
        #expect(tools.allSatisfy { $0.name.hasPrefix(OperationMCPCatalog.prefix) })
        #expect(tools.allSatisfy { !$0.route.isEmpty })
    }

    @Test func aToolNameIsDerivedFromItsRoute() {
        #expect(OperationMCPCatalog.toolName(for: ["usage", "limits"]) == "edith_usage_limits")
        #expect(
            OperationMCPCatalog.toolName(for: ["app", "check-updates"])
                == "edith_app_check_updates")
        #expect(OperationMCPCatalog.toolName(for: ["agent", "status"]) == "edith_agent_status")
    }

    @Test func knownOperationsAreReachableByName() {
        #expect(OperationMCPCatalog.tool(named: "edith_agent_status") != nil)
        #expect(OperationMCPCatalog.tool(named: "edith_extensions_enable") != nil)
        #expect(OperationMCPCatalog.tool(named: "edith_nothing_here") == nil)
    }

    @Test func everyToolAsksForJSON() {
        for tool in OperationMCPCatalog.tools {
            #expect(tool.arguments([], confirm: false).contains("--json"))
        }
    }

    @Test func aDestructiveToolPreviewsUntilItIsConfirmed() throws {
        let quit = try #require(OperationMCPCatalog.tool(named: "edith_app_quit"))

        #expect(quit.isDestructive)
        #expect(!quit.arguments([], confirm: false).contains("--yes"))
        #expect(quit.arguments([], confirm: true).contains("--yes"))
    }

    @Test func yesInsideArgumentsIsRefusedSoOnlyConfirmApplies() async throws {
        let result = await OperationMCPServer.call(
            CallTool.Parameters(
                name: "edith_app_quit", arguments: ["arguments": .array([.string("--yes")])]))
        #expect(result.isError == true)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            Issue.record("expected a text result")
            return
        }
        #expect(text == OperationMCPServer.confirmationInArguments)
    }

    @Test func aReadToolNeverGainsYes() throws {
        let status = try #require(OperationMCPCatalog.tool(named: "edith_agent_status"))

        #expect(!status.isDestructive)
        #expect(!status.arguments([], confirm: true).contains("--yes"))
    }

    @Test func callerArgumentsKeepTheirOrderAfterTheRoute() throws {
        let enable = try #require(OperationMCPCatalog.tool(named: "edith_extensions_enable"))

        let arguments = enable.arguments(["clipboard"], confirm: false)

        #expect(arguments == ["extensions", "enable", "--json", "clipboard"])
    }

    @Test(arguments: [["printf", "fixture"], ["printf", "fixture", "--json"]])
    func remoteCommandArgumentsStaySeparateFromTransportOptions(command: [String]) throws {
        let tool = try #require(OperationMCPCatalog.tool(named: "edith_machines_broadcast"))
        let parsed = try #require(
            try EdRoot.parseAsRoot(
                tool.arguments(["--only", "fixture", "--"] + command, confirm: false))
                as? MachinesBroadcastCommand)
        #expect(parsed.json)
        #expect(parsed.only == "fixture")
        #expect(parsed.command == command)
    }

    @Test func callerJSONOptionStillParsesWithTheTransportOption() throws {
        let tool = try #require(OperationMCPCatalog.tool(named: "edith_machines_broadcast"))
        let parsed = try #require(
            try EdRoot.parseAsRoot(
                tool.arguments(["--json", "--only", "fixture", "--", "pwd"], confirm: false))
                as? MachinesBroadcastCommand)
        #expect(parsed.json)
        #expect(parsed.command == ["pwd"])
    }

    @Test(arguments: [false, true])
    func confirmationIsParsedBeforeThePositionalSeparator(confirmed: Bool) throws {
        let tool = try #require(OperationMCPCatalog.tool(named: "edith_app_quit"))
        let parsed = try #require(
            try EdRoot.parseAsRoot(tool.arguments(["--"], confirm: confirmed)) as? AppQuitCommand)
        #expect(parsed.json)
        #expect(parsed.yes == confirmed)
    }

    @Test func onlyDestructiveToolsOfferConfirm() throws {
        let quit = try #require(OperationMCPCatalog.tool(named: "edith_app_quit"))
        let status = try #require(OperationMCPCatalog.tool(named: "edith_agent_status"))

        #expect(schemaProperties(for: quit).contains("confirm"))
        #expect(!schemaProperties(for: status).contains("confirm"))
        #expect(schemaProperties(for: status).contains("arguments"))
    }

    @Test func aDestructiveDescriptionSaysItPreviews() throws {
        let quit = try #require(OperationMCPCatalog.tool(named: "edith_app_quit"))
        #expect(OperationMCPServer.description(for: quit).contains("Previews by default"))
    }

    @Test func theServerListsOperationAndDatabaseToolsTogether() {
        let names = Set(OperationMCPServer.tools.map(\.name))
        #expect(names.contains("edith_agent_jobs"))
        #expect(names.count == OperationMCPCatalog.tools.count)
    }

    @Test func aMissingExecutableFailsRatherThanHanging() async throws {
        let status = try #require(OperationMCPCatalog.tool(named: "edith_agent_status"))

        let invocation = await OperationMCPRunner.run(
            status, arguments: [], confirm: false, executable: nil)

        #expect(invocation.failed)
        #expect(invocation.output.contains("could not be located"))
    }

    private func schemaProperties(for tool: OperationMCPTool) -> Set<String> {
        guard case let .object(root) = OperationMCPServer.schema(for: tool),
            case let .object(properties)? = root["properties"]
        else { return [] }
        return Set(properties.keys)
    }
}
