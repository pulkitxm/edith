import Foundation

public enum ToolProvisioning {
    public static let all: [CLIToolSpec] = [
        .youtubeDownloader, .ffmpeg, .claudeCode, .codex, .quinjet, .homebrew,
    ]

    public static func spec(id: String) -> CLIToolSpec? {
        all.first { $0.id == id }
    }
}
