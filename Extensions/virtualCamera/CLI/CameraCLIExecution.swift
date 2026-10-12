import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum CameraCLIEnvironment {
    static var engine: VirtualCameraEngine?
    @TaskLocal static var streamEngine: VirtualCameraEngine?
    static var currentEngine: VirtualCameraEngine? { streamEngine ?? engine }
    static var lifecycle: ((Bool) async throws -> [String])?
}
@MainActor enum CameraCLIExecution {
    private static var executing = false
    static func run(_ request: ExtensionCLIRequest, engine: VirtualCameraEngine) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        while executing {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        executing = true
        defer { executing = false }
        let previous = CameraCLIEnvironment.engine
        CameraCLIEnvironment.engine = engine
        defer { CameraCLIEnvironment.engine = previous }
        return try await ExtensionCLIExecution.run(CameraCommand.self, request: request)
    }
}
