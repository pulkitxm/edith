import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum AudioCLIEnvironment { static var engine: AnyObject? }
@MainActor enum AudioCLIExecution {
    private static var executing = false
    @available(macOS 14.4, *) static func run(_ request: ExtensionCLIRequest, engine: MixerEngine)
        async throws -> ExtensionCLIReply
    {
        try request.validate()
        while executing {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        executing = true
        defer { executing = false }
        let previous = AudioCLIEnvironment.engine
        AudioCLIEnvironment.engine = engine
        defer { AudioCLIEnvironment.engine = previous }
        return try await ExtensionCLIExecution.run(AudioCommand.self, request: request)
    }
}
