import EdithCore
import Foundation
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

    @Test func aReadToolNeverGainsYes() throws {
        let status = try #require(OperationMCPCatalog.tool(named: "edith_agent_status"))

        #expect(!status.isDestructive)
        #expect(!status.arguments([], confirm: true).contains("--yes"))
    }

    @Test func callerArgumentsKeepTheirOrderAfterTheRoute() throws {
        let enable = try #require(OperationMCPCatalog.tool(named: "edith_extensions_enable"))

        let arguments = enable.arguments(["clipboard"], confirm: false)

        #expect(arguments.prefix(3) == ["extensions", "enable", "clipboard"])
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

    @Test func aMissingExecutableFailsRatherThanHanging() throws {
        let status = try #require(OperationMCPCatalog.tool(named: "edith_agent_status"))

        let invocation = OperationMCPRunner.run(
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
