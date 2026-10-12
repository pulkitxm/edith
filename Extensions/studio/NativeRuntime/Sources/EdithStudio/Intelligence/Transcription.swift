import AVFoundation
import Foundation
import Speech

public enum StudioTranscription {
    public struct Word: Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public struct Cue: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
    }

    public static var canAskForPermission: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    static let tool = StudioTool(
        id: "ai.transcribe", title: "Transcribe",
        summary: "Turn speech in audio and video into text or subtitles, on this Mac.",
        symbol: "captions.bubble", group: .intelligence, inputs: [.audio, .video],
        produces: .kind(.document),
        options: [
            .choice(
                "format", "Save as",
                [
                    StudioChoice("txt", "Text"), StudioChoice("srt", "SRT subtitles"),
                    StudioChoice("vtt", "WebVTT subtitles"),
                ], default: "txt"),
            .choice(
                "language", "Language",
                [
                    StudioChoice("en-US", "English (US)"), StudioChoice("en-GB", "English (UK)"),
                    StudioChoice("en-IN", "English (India)"), StudioChoice("es-ES", "Spanish"),
                    StudioChoice("fr-FR", "French"), StudioChoice("de-DE", "German"),
                    StudioChoice("it-IT", "Italian"), StudioChoice("pt-BR", "Portuguese"),
                    StudioChoice("hi-IN", "Hindi"), StudioChoice("ja-JP", "Japanese"),
                    StudioChoice("zh-CN", "Chinese"),
                ], default: "en-US"),
        ],
        keywords: ["speech", "subtitles", "captions", "srt", "vtt", "text", "dictation"],
        actionTitle: "Transcribe", family: .audio
    ) { run in
        let words = try await transcribe(
            run.input, locale: Locale(identifier: run.settings.text("language")), run: run)
        guard !words.isEmpty else {
            throw StudioError.nothingToDo("No speech was found in \(run.input.lastPathComponent).")
        }
        let format = run.settings.text("format")
        let output = run.output(for: run.input, suffix: nil, ext: format)
        let text: String
        switch format {
        case "srt": text = srt(cues(from: words))
        case "vtt": text = vtt(cues(from: words))
        default: text = plain(words)
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
        run.note("Transcribed \(words.count) words.")
        return [output]
    }

    static func transcribe(_ url: URL, locale: Locale, run: StudioRun) async throws -> [Word] {
        guard canAskForPermission else {
            throw StudioError.unavailable(
                "Transcription runs in the Edith app, which can ask for speech recognition.")
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw StudioError.unavailable(
                "Allow speech recognition for Edith in System Settings > Privacy & Security.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
            recognizer.supportsOnDeviceRecognition
        else {
            throw StudioError.unavailable(
                "On-device speech recognition is not available for \(locale.identifier).")
        }
        run.status("Preparing audio")
        let audio = try await extractAudio(url, run: run)
        run.status("Listening")
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(
                        returning: result.bestTranscription.segments.map {
                            Word(
                                text: $0.substring, start: $0.timestamp,
                                end: $0.timestamp + $0.duration)
                        })
                }
            }
        }
    }

    static func extractAudio(_ url: URL, run: StudioRun) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw StudioError.nothingToDo("\(url.lastPathComponent) has no sound to transcribe.")
        }
        let audio = try run.scratch("audio").appendingPathComponent("speech.m4a")
        guard
            let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw StudioError.failed("The sound could not be read.") }
        export.outputURL = audio
        export.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw StudioError.failed(
                export.error?.localizedDescription ?? "The sound could not be read.")
        }
        return audio
    }

    public static func cues(from words: [Word], maxWords: Int = 8, maxDuration: Double = 3.5)
        -> [Cue]
    {
        var cues: [Cue] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(
                Cue(
                    start: first.start, end: max(last.end, first.start + 0.4),
                    text: current.map(\.text).joined(separator: " ")))
            current.removeAll()
        }
        for word in words {
            if let first = current.first,
                current.count >= maxWords || word.end - first.start > maxDuration
                    || (current.last.map { word.start - $0.end > 0.8 } ?? false)
            {
                flush()
            }
            current.append(word)
            if word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") {
                flush()
            }
        }
        flush()
        return cues
    }

    public static func plain(_ words: [Word]) -> String {
        var lines: [String] = []
        var line: [String] = []
        var previous: Word?
        for word in words {
            if let previous, word.start - previous.end > 1.5, !line.isEmpty {
                lines.append(line.joined(separator: " "))
                line.removeAll()
            }
            line.append(word.text)
            previous = word
        }
        if !line.isEmpty { lines.append(line.joined(separator: " ")) }
        return lines.joined(separator: "\n\n") + "\n"
    }

    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n"
            + cues.map { cue in
                "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(cue.text)\n"
            }.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double, separator: String) -> String {
        let total = max(0, seconds)
        let milliseconds = Int((total * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let secs = milliseconds / 1000 % 60
        return String(
            format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, milliseconds % 1000)
    }
}
