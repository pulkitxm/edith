import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum StudioCLIEnvironment {
    nonisolated(unsafe) static var defaults = SharedDefaults.store
    nonisolated(unsafe) static var workingDirectory = URL(fileURLWithPath: "/", isDirectory: true)
    nonisolated(unsafe) static var standardInput = Data()

    nonisolated static func url(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return
            (expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : workingDirectory.appendingPathComponent(expanded)).standardizedFileURL
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
    private static var running = false

    static func run(_ request: StudioCLIRequest, model: StudioModel) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !running else {
            throw ExtensionPeerError.rejected("Another Studio terminal command is running.")
        }
        running = true
        defer { running = false }
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        let previousDirectory = StudioCLIEnvironment.workingDirectory
        let previousInput = StudioCLIEnvironment.standardInput
        let previousColor = CLIStyle.forcedColor
        StudioCLIEnvironment.workingDirectory = URL(
            fileURLWithPath: request.workingDirectory, isDirectory: true)
        StudioCLIEnvironment.standardInput = request.standardInput
        CLIStyle.forcedColor = request.interactive
        defer {
            StudioCLIEnvironment.workingDirectory = previousDirectory
            StudioCLIEnvironment.standardInput = previousInput
            CLIStyle.forcedColor = previousColor
        }
        let previous = StudioCLIEnvironment.defaults
        StudioCLIEnvironment.defaults = model.defaults
        defer { StudioCLIEnvironment.defaults = previous }
        return try await ExtensionCLIExecution.run(StudioCommand.self, arguments: request.arguments)
    }
}
