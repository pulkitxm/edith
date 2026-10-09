import Foundation

enum MediaEncoding {
    static let evenFilter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    static let editableContainers: Set<String> = ["mp4", "mov", "m4v", "mkv"]
    static let mp4AudioCodecs: Set<String> = ["aac", "mp3", "alac"]

    static func videoContainer(for input: URL) -> String {
        let ext = input.pathExtension.lowercased()
        return editableContainers.contains(ext) ? ext : "mp4"
    }

    static func video(container: String, crf: Int = 20, preset: String = "fast") -> [String] {
        switch container {
        case "webm":
            return [
                "-c:v", "libvpx-vp9", "-crf", String(crf + 13), "-b:v", "0", "-row-mt", "1",
                "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p",
            ]
        case "avi":
            return ["-c:v", "mpeg4", "-q:v", "3", "-pix_fmt", "yuv420p"]
        default:
            return [
                "-c:v", "libx264", "-preset", preset, "-crf", String(crf), "-pix_fmt", "yuv420p",
            ]
        }
    }

    static func audio(
        container: String, source: StudioMediaInfo?, allowCopy: Bool, bitrate: String = "192k"
    ) -> [String] {
        let codec = source?.audioCodec ?? ""
        switch container {
        case "webm":
            if allowCopy, codec == "opus" || codec == "vorbis" { return ["-c:a", "copy"] }
            return ["-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            if allowCopy, codec == "mp3" { return ["-c:a", "copy"] }
            return ["-c:a", "libmp3lame", "-b:a", bitrate]
        case "mkv":
            if allowCopy, !codec.isEmpty { return ["-c:a", "copy"] }
            return ["-c:a", "aac", "-b:a", bitrate]
        default:
            if allowCopy, mp4AudioCodecs.contains(codec) { return ["-c:a", "copy"] }
            return ["-c:a", "aac", "-b:a", bitrate]
        }
    }

    static func finishing(container: String) -> [String] {
        ["mp4", "mov", "m4v"].contains(container) ? ["-movflags", "+faststart"] : []
    }

    static let primaryStreams = ["-map", "0:v:0", "-map", "0:a:0?"]

    static func even(_ value: Double) -> Int {
        max(2, Int(value / 2) * 2)
    }

    static func floorEven(_ value: Double) -> Int {
        max(0, Int(value / 2) * 2)
    }

    static func atempo(_ speed: Double) -> String {
        var remaining = speed
        var parts: [String] = []
        while remaining > 2.0001 {
            parts.append("atempo=2.0")
            remaining /= 2
        }
        while remaining < 0.4999 {
            parts.append("atempo=0.5")
            remaining /= 0.5
        }
        parts.append("atempo=" + String(format: "%.4f", remaining))
        return parts.joined(separator: ",")
    }

    struct AudioFormat {
        let ext: String
        let arguments: [String]
        let lossy: Bool
    }

    static let audioFormatChoices = [
        StudioChoice("mp3", "MP3"), StudioChoice("m4a", "M4A (AAC)"), StudioChoice("wav", "WAV"),
        StudioChoice("flac", "FLAC"), StudioChoice("opus", "Opus"), StudioChoice("ogg", "OGG"),
        StudioChoice("aiff", "AIFF"), StudioChoice("alac", "Apple Lossless"),
    ]

    static let bitrateChoices = [
        StudioChoice("96", "96 kbps"), StudioChoice("128", "128 kbps"),
        StudioChoice("192", "192 kbps"), StudioChoice("256", "256 kbps"),
        StudioChoice("320", "320 kbps"),
    ]

    static func audioFormat(_ name: String, bitrate: Int = 192, bitDepth: Int? = nil)
        -> AudioFormat
    {
        let rate = "\(bitrate)k"
        let deep = (bitDepth ?? 16) > 16
        switch name {
        case "mp3":
            return AudioFormat(
                ext: "mp3", arguments: ["-c:a", "libmp3lame", "-b:a", rate], lossy: true)
        case "wav":
            return AudioFormat(
                ext: "wav", arguments: ["-c:a", deep ? "pcm_s24le" : "pcm_s16le"], lossy: false)
        case "flac": return AudioFormat(ext: "flac", arguments: ["-c:a", "flac"], lossy: false)
        case "opus":
            return AudioFormat(
                ext: "opus", arguments: ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"],
                lossy: true)
        case "ogg":
            return AudioFormat(
                ext: "ogg", arguments: ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"],
                lossy: true)
        case "aiff":
            return AudioFormat(
                ext: "aiff", arguments: ["-c:a", deep ? "pcm_s24be" : "pcm_s16be"], lossy: false)
        case "alac": return AudioFormat(ext: "m4a", arguments: ["-c:a", "alac"], lossy: false)
        default:
            return AudioFormat(ext: "m4a", arguments: ["-c:a", "aac", "-b:a", rate], lossy: true)
        }
    }

    static func sameAudioFormat(for input: URL, info: StudioMediaInfo?) -> AudioFormat {
        let bitrate = info?.bitRate.map { min(320, max(96, $0 / 1000)) } ?? 192
        switch input.pathExtension.lowercased() {
        case "mp3": return audioFormat("mp3", bitrate: bitrate)
        case "wav": return audioFormat("wav", bitDepth: info?.bitDepth)
        case "flac": return audioFormat("flac")
        case "opus": return audioFormat("opus", bitrate: bitrate)
        case "ogg", "oga": return audioFormat("ogg", bitrate: bitrate)
        case "aif", "aiff", "aifc": return audioFormat("aiff", bitDepth: info?.bitDepth)
        case "m4a", "alac":
            return info?.audioCodec == "alac"
                ? audioFormat("alac") : audioFormat("m4a", bitrate: bitrate)
        default: return audioFormat("m4a", bitrate: bitrate)
        }
    }
}
