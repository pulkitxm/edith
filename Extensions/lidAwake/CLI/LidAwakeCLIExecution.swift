import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum LidAwakeCLIEnvironment { static var worker: LidAwakeWorker? }
@MainActor enum LidAwakeCLIExecution {
    private static var executing = false
    static func run(_ request: ExtensionCLIRequest, worker: LidAwakeWorker) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        while executing {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        executing = true
        defer { executing = false }
        let previous = LidAwakeCLIEnvironment.worker
        LidAwakeCLIEnvironment.worker = worker
        defer { LidAwakeCLIEnvironment.worker = previous }
        return try await ExtensionCLIExecution.run(
            LidAwakeCLICommand.self, request: request)
    }
}
