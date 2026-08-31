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
    nonisolated(unsafe) public static var makeSecretStore:
        @Sendable () throws -> any DatabaseSecretStore = {
            try DatabaseKeychainSecretStore()
        }
    nonisolated(unsafe) public static var readPassword: @Sendable () throws -> String = {
        try SecretInput.readFromStdin("database password")
    }

    public static func reset() {
        makeSender = { DatabaseBrokerCommandClient() }
        runMCPServer = { try await DatabaseMCPServer().run() }
        makeSecretStore = { try DatabaseKeychainSecretStore() }
        readPassword = { try SecretInput.readFromStdin("database password") }
    }
}
