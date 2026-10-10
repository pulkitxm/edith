import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

final class StudioCLIDefaults: @unchecked Sendable {
    let store: UserDefaults
    init(_ store: UserDefaults) { self.store = store }
}

@MainActor enum StudioCLIEnvironment {
    @TaskLocal nonisolated static var scopedDefaults: StudioCLIDefaults?

    nonisolated static var defaults: UserDefaults { scopedDefaults?.store ?? SharedDefaults.store }
    nonisolated static var workingDirectory: URL {
        URL(
            fileURLWithPath: ExtensionCLIContext.request?.workingDirectory ?? "/", isDirectory: true
        )
    }
    nonisolated static var standardInput: Data {
        ExtensionCLIContext.request?.standardInput ?? Data()
    }

    nonisolated static func url(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
    }

    static var record:
        (StudioRecordRequest, String, Bool, Bool, Bool) async throws -> StudioRecordSnapshot = {
            request, source, systemAudio, microphone, showCursor in
            guard #available(macOS 15.0, *) else {
                throw CLIFailure.unavailable("Screen recording needs macOS 15 or later.")
            }
            return try await StudioRecordBridge.shared.perform(
                request, source: source, systemAudio: systemAudio,
                microphone: microphone, showCursor: showCursor)
        }
    static var openProject: (VideoEditorService.OpenRequest, Double) async throws -> Void = {
        request, timeout in
        try await VideoEditorOpenBridge.shared.open(request, timeout: timeout)
    }
}

@MainActor enum StudioCLIExecution {
    static func run(_ request: ExtensionCLIRequest, model: StudioModel) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        return try await StudioCLIEnvironment.$scopedDefaults.withValue(
            StudioCLIDefaults(model.defaults)
        ) {
            try await ExtensionCLIExecution.run(StudioCommand.self, request: request)
        }
    }
}
