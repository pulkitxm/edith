import EdithExtensionSupport
import Observation

@MainActor @Observable final class EmbeddedMusicTools {
    static let shared = EmbeddedMusicTools()
    static let names = ["yt-dlp", "ffmpeg", "deno", "gallery-dl"]
    static func purpose(of name: String) -> String {
        switch name {
        case "yt-dlp": "Required. Downloads videos and audio from most sites."
        case "ffmpeg": "Converts audio and merges the best video and sound."
        case "deno": "Helps yt-dlp read sites that need scripts to load."
        case "gallery-dl": "Saves photos, galleries and carousels from posts."
        default: ""
        }
    }
    var installed: Set<String> = []
    var installing: String?
    var error: String?
    func refresh() { EmbeddedMusicRemote.shared.send(.refreshTools) }
    func install(_ name: String) { EmbeddedMusicRemote.shared.send(.installTool, target: name) }
}

enum EmbeddedMusicFade {
    static let enabledKey = "musicCrossfadeEnabled"
    static let secondsKey = "musicCrossfadeSeconds"
    static let defaultSeconds = 2.0
    static let secondsRange = 0.5...8.0
}
