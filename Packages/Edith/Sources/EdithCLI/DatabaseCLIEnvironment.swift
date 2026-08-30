import EdithDatabase
import EdithDatabaseMCP

public enum DatabaseCLIEnvironment {
    nonisolated(unsafe) public static var makeSender:
        @Sendable () -> any DatabaseBrokerCommandSending = {
            DatabaseBrokerCommandClient()
        }
    nonisolated(unsafe) public static var runMCPServer: @Sendable () async throws -> Void = {
        try await DatabaseMCPServer().run()
    }

    public static func reset() {
        makeSender = { DatabaseBrokerCommandClient() }
        runMCPServer = { try await DatabaseMCPServer().run() }
    }
}
