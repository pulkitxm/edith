import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum MusicCLIEnvironment {
    static var sharedDefaults: UserDefaults { SharedDefaults.store }
    static var standardDefaults: UserDefaults { SharedDefaults.store }
    static var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    static var readBuiltin: () async -> PlayerSnapshot = { PlayerSnapshot(player: .builtin) }
    static var sendBuiltin: (MusicTransportRequest) -> Void = { _ in }
    static var refreshLibrary: () -> Void = {}
    static var renamed: (String, String) -> Void = { _, _ in }
    static var available = false
    static var runAppleScript: (String, TimeInterval) throws -> String = AppleScriptHost.execute

    static func requirePlayer() throws {
        guard available else {
            throw CLIFailure.unavailable(
                "the Music extension is off", hint: "run `ed extensions enable music`")
        }
    }
}

@MainActor enum MusicCLIExecution {
    static func run(_ request: ExtensionCLIRequest, player: LocalMusicPlayer) async throws
        -> ExtensionCLIReply
    {
        try await run(
            request,
            read: {
                PlayerSnapshot(
                    player: .builtin, isRunning: true, isPlaying: player.isPlaying,
                    title: player.current.map { ($0.relativePath as NSString).lastPathComponent }
                        ?? "", elapsedSeconds: player.elapsed,
                    durationSeconds: player.trackDuration, volume: player.volume,
                    trackPath: player.current?.relativePath)
            }, send: player.perform, refresh: player.rescan, renamed: player.renameCurrent)
    }

    static func run(
        _ request: ExtensionCLIRequest, read: @escaping () async -> PlayerSnapshot,
        send: @escaping (MusicTransportRequest) -> Void, refresh: @escaping () -> Void,
        renamed: @escaping (String, String) -> Void
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let priorRead = MusicCLIEnvironment.readBuiltin
        let priorSend = MusicCLIEnvironment.sendBuiltin
        let priorRefresh = MusicCLIEnvironment.refreshLibrary
        let priorRename = MusicCLIEnvironment.renamed
        let priorAvailable = MusicCLIEnvironment.available
        MusicCLIEnvironment.readBuiltin = read
        MusicCLIEnvironment.sendBuiltin = send
        MusicCLIEnvironment.refreshLibrary = refresh
        MusicCLIEnvironment.renamed = renamed
        MusicCLIEnvironment.available = true
        defer {
            MusicCLIEnvironment.readBuiltin = priorRead
            MusicCLIEnvironment.sendBuiltin = priorSend
            MusicCLIEnvironment.refreshLibrary = priorRefresh
            MusicCLIEnvironment.renamed = priorRename
            MusicCLIEnvironment.available = priorAvailable
        }
        return try await ExtensionCLIExecution.run(MusicCommand.self, arguments: request.arguments)
    }
}
