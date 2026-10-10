import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable
final class DownloadsTools {
    static let shared = DownloadsTools()
    static let names = ["yt-dlp", "ffmpeg", "deno", "gallery-dl"]
    private(set) var installed: Set<String> = []
    private(set) var installing: String?
    var error: String?
    var didChange: (() -> Void)?
    private let remote: DownloadsUIBridge?
    init(remote: DownloadsUIBridge? = nil) { self.remote = remote }
    @ObservationIgnored private let tasks = DownloadsTaskOwner()

    func refresh() {
        if let remote {
            tasks.start { [weak self] in
                if let value = try? await remote.configuration(), !Task.isCancelled {
                    self?.apply(value.tools)
                }
            }
            return
        }
        installed = Set(Self.names.filter { CLIToolEnvironment.executable(named: $0) != nil })
    }

    func install(_ name: String) {
        guard Self.names.contains(name), installing == nil else { return }
        if let remote {
            installing = name
            tasks.start { [weak self] in
                defer { self?.installing = nil }
                do {
                    try await remote.perform(.init(action: "install", tool: name))
                    repeat {
                        let value = try await remote.configuration()
                        try Task.checkCancellation()
                        self?.apply(value.tools)
                        if value.tools.installing == nil { break }
                        try await Task.sleep(for: .seconds(2))
                    } while !Task.isCancelled
                    self?.didChange?()
                } catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
            }
            return
        }
        guard let brew = CLIToolEnvironment.executable(named: "brew") else {
            error = "Install Homebrew to add the tools used for media downloads."
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
                    throw DownloadsError(
                        "\(name) could not be installed. Check Homebrew and try again.")
                }
                refresh()
                didChange?()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    var snapshot: DownloadsToolsSnapshot {
        .init(installed: installed, installing: installing, error: error)
    }
    func apply(_ value: DownloadsToolsSnapshot) {
        installed = value.installed; installing = value.installing; error = value.error
    }
    func shutdown() async { await tasks.shutdown(); installing = nil; didChange = nil }
}
