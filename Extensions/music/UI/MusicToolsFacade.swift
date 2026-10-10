import EdithExtensionSupport
import Observation

@MainActor @Observable final class EmbeddedMusicTools {
    static let shared = EmbeddedMusicTools()
    static let names = ["yt-dlp", "ffmpeg", "deno", "gallery-dl"]
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
