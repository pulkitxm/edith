import DownloadsHistory
import EdithExtensionSupport
import Foundation
import MusicHistory

@main struct HistoryChild {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let owner = arguments[1]
        let file = URL(fileURLWithPath: arguments[2])
        let root = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let events = root.appendingPathComponent("admissions.json")
        let run:
            @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
                CLICommandResult = { request, _ in
                    let url = request.arguments.last!
                    _ = try PersistentJSONFile.update([String].self, at: events, missing: []) {
                        $0.append(url)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                    let output = root.appendingPathComponent(
                        URL(string: url)!.lastPathComponent + ".m4a")
                    try Data("synthetic child output".utf8).write(to: output)
                    return CLICommandResult(terminationStatus: 0, output: output.path + "\n")
                }
        let url = URL(string: "https://example.invalid/\(owner)-child")!
        if owner == "music" {
            let worker = MusicHistory.DownloadWorker(
                file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
                runCommand: run)
            _ = try await worker.mutate(
                .enqueue(urls: [url], prefix: "", kind: .audio, outputDirectory: root))
            try await worker.start()
            for _ in 0..<1_000 {
                let snapshot = await worker.snapshot()
                if snapshot.queued == 0 && snapshot.records.allSatisfy(\.isFinished) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await worker.stop()
        } else {
            let worker = DownloadsHistory.DownloadWorker(
                file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
                runCommand: run)
            _ = try await worker.mutate(
                .enqueue(urls: [url], prefix: "", kind: .audio, outputDirectory: root))
            try await worker.start()
            for _ in 0..<1_000 {
                let snapshot = await worker.snapshot()
                if snapshot.queued == 0 && snapshot.records.allSatisfy(\.isFinished) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await worker.stop()
        }
    }
}
