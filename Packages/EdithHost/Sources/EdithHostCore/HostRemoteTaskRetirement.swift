import Foundation

@MainActor
enum HostRemoteTaskRetirement {
    static func cancelAndJoin(
        cancel: () -> Void,
        joinLaunch: () async -> Void,
        joinConfiguration: () async -> Void
    ) async {
        cancel()
        await joinLaunch()
        await joinConfiguration()
    }
}
