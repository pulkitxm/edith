import AVFoundation
import Speech

enum VideoTranscription {
    struct Word {
        let text: String
        let start: Double
        let end: Double
    }

    static func transcribe(_ video: URL, locale: Locale = Locale(identifier: "en-US")) async throws
        -> [Word]
    {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw Error.permission }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
            recognizer.supportsOnDeviceRecognition
        else { throw Error.unavailable }

        let asset = AVURLAsset(url: video)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw Error.noAudio
        }
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transcription-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        guard
            let export = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A)
        else { throw Error.noAudio }
        export.outputURL = audio
        export.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else { throw export.error ?? Error.noAudio }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
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

    enum Error: LocalizedError {
        case permission, unavailable, noAudio
        var errorDescription: String? {
            switch self {
            case .permission: "Allow speech recognition in System Settings to generate captions."
            case .unavailable: "On-device speech recognition is unavailable for this language."
            case .noAudio: "This video does not contain an audio track."
            }
        }
    }
}
