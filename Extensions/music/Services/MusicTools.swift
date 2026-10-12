import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable
final class MusicTools {
    static let shared = MusicTools()
    static let names = ["yt-dlp", "ffmpeg", "deno", "gallery-dl"]
    private(set) var installed: Set<String> = []
    private(set) var installing: String?
    var error: String?
    @ObservationIgnored private let tasks = MusicTaskOwner()

    func refresh() {
        installed = Set(Self.names.filter { CLIToolEnvironment.executable(named: $0) != nil })
    }

    func install(_ name: String) {
        guard Self.names.contains(name), installing == nil else { return }
        guard let brew = CLIToolEnvironment.executable(named: "brew") else {
            error = "Install Homebrew to add the tools used for music downloads."
            return
        }
        installing = name
        error = nil
        tasks.start { [weak self] in
            guard let self else { return }
            defer { installing = nil }
            do {
                let result = try await CLICommandRunner.runLocal(
                    CLICommandRequest(
                        executableURL: brew, arguments: ["install", name],
                        environment: CLIToolEnvironment.sanitized(), timeout: 1800,
                        maximumOutputBytes: 262_144, terminatesProcessGroup: true),
                    onLine: { _ in })
                try Task.checkCancellation()
                guard result.terminationStatus == 0 else {
                    throw MusicDownloadError(
                        "\(name) could not be installed. Check Homebrew and try again.")
                }
                refresh()
                YoutubeDownloader.shared.checkAvailability()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func shutdown() { tasks.shutdown(); installing = nil }
}
