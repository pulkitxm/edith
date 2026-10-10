import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum CleanerCLIEnvironment {
    static var home: URL {
        if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil {
            return ExtensionData.root
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var drives: () -> [DriveInfo] = { JunkScanner.drives() }
    static var reclaim: @Sendable ([JunkItem], Progress) -> CleanerCleanResult = { items, token in
        var reclaimed: Int64 = 0
        var requested: Int64 = 0
        var count = 0
        for item in items {
            guard !token.isCancelled else { break }
            let result = CleanerOperationExecution.clean([item])
            reclaimed += result.reclaimedBytes
            requested += result.requestedBytes
            count += result.items
        }
        return CleanerCleanResult(
            items: count, requestedBytes: requested, reclaimedBytes: reclaimed)
    }
    static func clean(_ items: [JunkItem]) async throws -> CleanerCleanResult {
        let token = Progress(totalUnitCount: 0)
        let reclaim = reclaim
        return try await withTaskCancellationHandler {
            let result = try await BlockingWork.perform { reclaim(items, token) }
            try Task.checkCancellation()
            return result
        } onCancel: {
            token.cancel()
        }
    }
}
@MainActor enum CleanerCLIExecution {
    static func run(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply {
        try request.validate()
        return try await ExtensionCLIExecution.run(
            CleanerCommand.self, arguments: request.arguments)
    }
}
