import Foundation

public enum ToolProvisioning {
    public static let all: [CLIToolSpec] = [
        .youtubeDownloader, .galleryDownloader, .ffmpeg, .qpdf, .deno, .claudeCode, .codex,
        .quinjet, .git, .githubCLI, .homebrew, .tectonic, .pukbot,
    ]

    public static func spec(id: String) -> CLIToolSpec? {
        all.first { $0.id == id }
    }
}
