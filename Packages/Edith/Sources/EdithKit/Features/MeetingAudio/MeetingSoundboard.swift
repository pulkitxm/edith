import AVFoundation
import Foundation

public enum MeetingSound: String, CaseIterable, Sendable {
    case chime, success, airhorn, applause, thunder, drumroll, rimshot, scratch, pop, countdown,
        whoosh, error

    public var name: String {
        switch self {
        case .airhorn: "Air horn"
        case .rimshot: "Rim shot"
        case .scratch: "Record scratch"
        default: rawValue.capitalized
        }
    }

    public var symbol: String {
        switch self {
        case .chime, .success: "bell"
        case .airhorn: "megaphone"
        case .applause: "hands.clap"
        case .thunder: "cloud.bolt"
        case .drumroll, .rimshot: "music.note"
        case .scratch: "opticaldisc"
        case .pop: "bubble"
        case .countdown: "timer"
        case .whoosh: "wind"
        case .error: "exclamationmark.triangle"
        }
    }

    public var identifier: String { "soundboard:\(rawValue)" }

    public var duration: Double {
        switch self {
        case .applause, .thunder: 3
        case .drumroll, .countdown: 2
        case .pop, .rimshot: 0.7
        default: 1.2
        }
    }

    public func clip() throws -> MeetingAudioClip {
        let directory = MeetingAudioLibrary.directory.appendingPathComponent(
            "soundboard", isDirectory: true)
        let url = directory.appendingPathComponent(rawValue).appendingPathExtension("caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let buffer = try render()
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
        }
        return MeetingAudioClip(name: name, path: url.path, speech: false)
    }

    public func render() throws -> AVAudioPCMBuffer {
        let rate = 48000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * rate)),
            let channel = buffer.floatChannelData?[0]
        else { throw MeetingAudioLibrary.error("Could not create the sound effect.") }
        buffer.frameLength = buffer.frameCapacity
        var seed: UInt64 = 17
        var lowNoise = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / rate
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Double(seed >> 32) / Double(UInt32.max) * 2 - 1
            lowNoise += 0.015 * (noise - lowNoise)
            let fade = min(1, time * 200) * min(1, (duration - time) * 100)
            let value: Double
            switch self {
            case .chime:
                value = tone(880, time) * exp(-time * 4) + tone(1320, time) * exp(-time * 6) * 0.4
            case .success:
                let step = min(2, Int(time / 0.18))
                let frequencies = [523.25, 659.25, 783.99]
                value = tone(frequencies[step], time) * exp(-max(0, time - 0.36) * 5) * 0.6
            case .airhorn:
                value =
                    (tone(220, time) + tone(277.18, time) + tone(440, time) * 0.5) * 0.28
                    * min(1, max(0, 1.05 - time) * 10)
            case .applause:
                let pulse = pow(max(0, sin(time * 93) * cos(time * 47)), 3)
                value = noise * (0.12 + pulse * 0.8) * sin(.pi * time / duration)
            case .thunder:
                value =
                    (lowNoise * 5 + noise * exp(-time * 12) * 0.5)
                    * exp(-time * 0.8) * (0.7 + 0.3 * sin(time * 11))
            case .drumroll:
                let hit = time.truncatingRemainder(dividingBy: 0.075)
                value =
                    (noise * 0.7 + tone(160, hit) * 0.3) * exp(-hit * 65)
                    * (0.2 + 0.6 * time / duration)
            case .rimshot:
                value =
                    tone(180, time) * exp(-time * 25) * 0.6
                    + noise * exp(-max(0, time - 0.17) * 18) * (time >= 0.17 ? 0.5 : 0)
            case .scratch:
                value =
                    (tone(400 + sin(time * 18) * 260, time) * 0.5 + noise * 0.3)
                    * exp(-time * 2) * pow(sin(time * 15), 2)
            case .pop:
                value = sin(2 * .pi * (700 * time - 1800 * time * time)) * exp(-time * 30) * 0.8
            case .countdown:
                let beat = time.truncatingRemainder(dividingBy: 0.6)
                value = tone(time >= 1.8 ? 1320 : 660, time) * exp(-beat * 24) * 0.7
            case .whoosh:
                value = (noise * 0.5 + lowNoise * 2) * pow(sin(.pi * time / duration), 3)
            case .error:
                value = (tone(220, time) + tone(233.08, time)) * 0.3 * exp(-time * 3)
            }
            channel[frame] = Float(max(-0.9, min(0.9, value * fade)))
        }
        return buffer
    }

    private func tone(_ frequency: Double, _ time: Double) -> Double {
        sin(2 * .pi * frequency * time)
    }
}
