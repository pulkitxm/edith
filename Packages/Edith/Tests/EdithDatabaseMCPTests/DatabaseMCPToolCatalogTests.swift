import MCP
import Testing

@testable import EdithDatabaseMCP

@Suite struct DatabaseMCPToolCatalogTests {
    @Test func exposesBoundedReadOnlyConnectionAndCapabilityTools() {
        #expect(
            DatabaseMCPToolCatalog.tools.map(\.name)
                == ["database_connections", "database_capabilities"])

        for tool in DatabaseMCPToolCatalog.tools {
            #expect(tool.annotations.readOnlyHint == true)
            #expect(tool.annotations.destructiveHint == false)
            #expect(tool.annotations.idempotentHint == true)
            #expect(tool.annotations.openWorldHint == false)
            #expect(tool.inputSchema.objectValue?["type"]?.stringValue == "object")
            #expect(tool.inputSchema.objectValue?["additionalProperties"]?.boolValue == false)
            #expect(tool.outputSchema?.objectValue?["type"]?.stringValue == "object")
            #expect(tool.outputSchema?.objectValue?["required"]?.arrayValue == ["status"])
        }

        let connectionProperties =
            DatabaseMCPToolCatalog.connections.inputSchema.objectValue?["properties"]?
            .objectValue
        #expect(connectionProperties?["action"] != nil)
        #expect(connectionProperties?["connection_id"] != nil)
        #expect(connectionProperties?["search"] != nil)

        let capabilityRequired =
            DatabaseMCPToolCatalog.capabilities.inputSchema.objectValue?["required"]?
            .arrayValue
        #expect(capabilityRequired == ["connection_id"])
    }
}
