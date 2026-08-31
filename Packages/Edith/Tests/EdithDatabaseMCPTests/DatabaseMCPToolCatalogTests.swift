import MCP
import Testing

@testable import EdithDatabaseMCP

@Suite struct DatabaseMCPToolCatalogTests {
    @Test func exposesBoundedReadOnlyConnectionAndCapabilityTools() {
        #expect(
            DatabaseMCPToolCatalog.tools.map(\.name)
                == [
                    "database_connections", "database_capabilities", "database_browse",
                    "database_query",
                ])

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

        let browseProperties =
            DatabaseMCPToolCatalog.browse.inputSchema.objectValue?["properties"]?.objectValue
        #expect(browseProperties?["object_path"]?.objectValue?["maxItems"]?.intValue == 32)
        #expect(browseProperties?["page_size"]?.objectValue?["maximum"]?.intValue == 500)
        #expect(
            browseProperties?["continuation"]?.objectValue?["maxLength"]?.intValue == 32_768)

        let queryProperties =
            DatabaseMCPToolCatalog.query.inputSchema.objectValue?["properties"]?.objectValue
        #expect(queryProperties?["command"]?.objectValue?["maxLength"]?.intValue == 262_144)
        #expect(queryProperties?["language"]?.objectValue?["enum"]?.arrayValue?.count == 5)
    }
}
