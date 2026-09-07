import EdithDatabase
import EdithDatabaseMCP
import Foundation

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
    nonisolated(unsafe) public static var readQueryText: @Sendable (String?) throws -> String = {
        path in
        let data: Data
        if let path {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIFailure.usage("database query input must be UTF-8")
        }
        return text
    }

    public static func reset() {
        makeSender = { DatabaseBrokerCommandClient() }
        runMCPServer = { try await DatabaseMCPServer().run() }
        makeSecretStore = { try DatabaseKeychainSecretStore() }
        readPassword = { try SecretInput.readFromStdin("database password") }
        readQueryText = { path in
            let data: Data
            if let path {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                data = FileHandle.standardInput.readDataToEndOfFile()
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIFailure.usage("database query input must be UTF-8")
            }
            return text
        }
    }
}
