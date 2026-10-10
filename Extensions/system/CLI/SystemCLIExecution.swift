import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum SystemCLIEnvironment { static var operations: RunningAppOperationCenter? }

@MainActor enum SystemCLIExecution {
    private static var executing = false
    static func run(_ request: ExtensionCLIRequest, operations: RunningAppOperationCenter)
        async throws -> ExtensionCLIReply
    {
        try request.validate()
        while executing {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        executing = true
        defer { executing = false }
        let previous = SystemCLIEnvironment.operations
        SystemCLIEnvironment.operations = operations
        defer { SystemCLIEnvironment.operations = previous }
        return try await ExtensionCLIExecution.run(AppsCommand.self, request: request)
    }
}
