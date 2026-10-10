import EdithExtensionUI
import EdithExtensionSupport
import Foundation

enum MediaDownloadRequest {
    static func gallery(_ record: DownloadRecord, executable: URL) -> CLICommandRequest {
        let directory = URL(
            fileURLWithPath: record.outputFilename
                ?? DownloadQueue.outputTemplate(
                    prefix: "",
                    directory: MediaDownloadInput.defaultDirectory(for: record.kind ?? .post))
        )
        .deletingLastPathComponent().appendingPathComponent(record.id.uuidString)
        var arguments = [
            "--config-ignore", "--no-input", "--no-colors", "--retries", "2",
            "--http-timeout", "30", "--range", "1-100", "--directory", directory.path,
            "--filename", "{category}_{id|post_id|tweet_id|filename}_{num|filename}.{extension}",
            "--Print", "after:{_path}", "--Print", "skip:{_path}",
        ]
        if record.kind == .images {
            arguments += [
                "--filter",
                "extension.lower() in ('jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'heic', 'tiff', 'bmp')",
            ]
        }
        if let browser = record.browser {
            arguments += ["--cookies-from-browser", browser.rawValue]
        }
        arguments += ["--", record.url.absoluteString]
        return CLICommandRequest(
            executableURL: executable, arguments: arguments,
            environment: CLIToolEnvironment.sanitized(), timeout: 7_200,
            maximumOutputBytes: 2 << 20, terminatesProcessGroup: true)
    }
}
