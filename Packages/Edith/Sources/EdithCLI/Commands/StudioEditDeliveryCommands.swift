import ArgumentParser
import Darwin
import Edith
import Foundation

extension VideoDeliverySettings.Codec: ExpressibleByArgument {}
extension VideoDeliverySettings.AudioCodec: ExpressibleByArgument {}
extension VideoDeliverySettings.ColorSpace: ExpressibleByArgument {}
extension VideoAudioDeliverySettings.Container: ExpressibleByArgument {}

struct StudioEditDeliveryRange: ParsableArguments {
    @Option(help: "First output frame to include, zero-based. Supply both range bounds.")
    var startFrame: Int64?
    @Option(
        help: "Exclusive output-frame end. Supply both range bounds; effects keep project timing.")
    var endFrame: Int64?

    func validate() throws {
        guard (startFrame == nil) == (endFrame == nil) else {
            throw ValidationError("Provide both --start-frame and --end-frame, or neither.")
        }
        if let startFrame, let endFrame, startFrame < 0 || endFrame <= startFrame {
            throw ValidationError("Choose 0 <= start-frame < end-frame.")
        }
    }

    var selection: VideoDeliveryFrameRange? {
        guard let startFrame, let endFrame else { return nil }
        return VideoDeliveryFrameRange(startFrame: startFrame, endFrame: endFrame)
    }
}

struct StudioEditRender: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Encode native video and return a measured delivery report.",
        discussion:
            "H.264 and HEVC use .mp4; ProRes uses .mov. SIGINT/SIGTERM cancel cooperatively without replacing the destination."
    )
    @Argument var project: String
    @Option(help: "Destination .mp4 or .mov file, matching the codec.") var output: String
    @Option(help: "Video codec. hevc10 and ProRes retain high-precision frames.")
    var codec: VideoDeliverySettings.Codec = .h264
    @Option(help: "Video bits per second, 100000...1000000000; unused for ProRes.")
    var bitRate = 40_000_000
    @Option(help: "Maximum frames between keyframes, 1...10000; unused for ProRes.")
    var keyFrameInterval = 120
    @Option(
        help:
            "Audio codec; defaults to pcm for ProRes, aac otherwise. copy preserves validated full-stream AAC packets."
    )
    var audioCodec: VideoDeliverySettings.AudioCodec?
    @Option(
        help:
            "Required with --audio-codec copy: the single unedited independent soundtrack track ID."
    )
    var audioCopyTrack: String?
    @Option(help: "AAC bits per second, 32000...320000; mono maximum 256000.")
    var audioBitRate = 320_000
    @Option(help: "Audio samples per second: 44100, 48000, or 96000 (PCM only).")
    var audioSampleRate = 48_000
    @Option(help: "Audio channel count: 1 or 2.") var audioChannels = 2
    @Option(help: "Output color space; defaults to the project/composition, or rec709.")
    var colorSpace: VideoDeliverySettings.ColorSpace?
    @Flag(help: "Require hardware encoding; supported for H.264 and HEVC only.")
    var requireHardware = false
    @Flag(help: "Emit at most 101 progress updates to stderr; JSON lines with --json.")
    var progress = false
    @OptionGroup var range: StudioEditDeliveryRange
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            var settings = VideoDeliverySettings()
            settings.codec = codec
            settings.bitRate = bitRate
            settings.keyFrameInterval = keyFrameInterval
            settings.audioCodec = audioCodec ?? (codec.fileExtension == "mov" ? .pcm : .aac)
            settings.audioBitRate = audioBitRate
            settings.audioSampleRate = audioSampleRate
            settings.audioChannels = audioChannels
            settings.audioCopyTrackID = audioCopyTrack
            settings.colorSpace = colorSpace
            settings.requireHardware = requireHardware
            let delivery = settings
            let result = try await StudioEditExecution.run(progress: progress, json: options.json) {
                update in
                try await VideoEditorService.render(
                    StudioEditBridge.url(project), to: StudioEditBridge.url(output),
                    overwrite: options.overwrite, settings: delivery, range: range.selection,
                    progress: update)
            }
            try StudioEditBridge.printResult(result, json: options.json)
        }
    }
}

struct StudioEditRenderAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render-audio", abstract: "Encode the native audio mix as WAV, AIFF, or M4A.",
        discussion:
            "WAV and AIFF use 24-bit PCM; M4A uses AAC. The measured report includes the sample-frame count and SHA-256."
    )
    @Argument var project: String
    @Option(help: "Destination file, with the extension matching --container.") var output: String
    @Option(help: "Audio output container.") var container: VideoAudioDeliverySettings.Container =
        .wav
    @Option(help: "Samples per second: 44100, 48000, or 96000 (PCM only).") var sampleRate = 48_000
    @Option(help: "Channel count: 1 or 2.") var channels = 2
    @Option(help: "AAC bits per second, 32000...320000; mono maximum 256000.") var bitRate = 320_000
    @Flag(help: "Emit at most 101 progress updates to stderr; JSON lines with --json.")
    var progress = false
    @OptionGroup var range: StudioEditDeliveryRange
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            var settings = VideoAudioDeliverySettings()
            settings.container = container
            settings.sampleRate = sampleRate
            settings.channels = channels
            settings.bitRate = bitRate
            let delivery = settings
            let result = try await StudioEditExecution.run(progress: progress, json: options.json) {
                update in
                try await VideoEditorService.renderAudio(
                    StudioEditBridge.url(project), to: StudioEditBridge.url(output),
                    overwrite: options.overwrite, settings: delivery, range: range.selection,
                    progress: update)
            }
            try StudioEditBridge.printResult(result, json: options.json)
        }
    }
}

struct StudioEditInterrupted: LocalizedError {
    let signal: Int32
    var errorDescription: String? { "Delivery cancelled." }
}

final class StudioEditProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var percent = -1
    private var receivedSignal: Int32?
    private let emit: @Sendable (Int) -> Void

    init(emit: @escaping @Sendable (Int) -> Void) { self.emit = emit }

    func update(_ fraction: Double) {
        guard fraction.isFinite else { return }
        lock.withLock {
            let next = Int((min(1, max(0, fraction)) * 100).rounded(.down))
            guard next > percent else { return }
            percent = next
            emit(next)
        }
    }

    func interrupt(_ signal: Int32) {
        lock.withLock { if receivedSignal == nil { receivedSignal = signal } }
    }

    var interruption: StudioEditInterrupted {
        lock.withLock { StudioEditInterrupted(signal: receivedSignal ?? SIGINT) }
    }
}

enum StudioEditExecution {
    static func run<T: Sendable>(
        progress: Bool, json: Bool,
        operation: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> T
    ) async throws -> T {
        let state = StudioEditProgress { percent in
            guard progress else { return }
            if json {
                CLIOut.note("{\"version\":1,\"event\":\"progress\",\"percent\":\(percent)}")
            } else {
                CLIOut.note("rendering: \(percent)%")
            }
        }
        let task = Task {
            try Task.checkCancellation()
            return try await operation { state.update($0) }
        }
        let previousInterrupt = Darwin.signal(SIGINT, SIG_IGN)
        let previousTerminate = Darwin.signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                state.interrupt(number)
                task.cancel()
            }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            Darwin.signal(SIGINT, previousInterrupt)
            Darwin.signal(SIGTERM, previousTerminate)
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if task.isCancelled { throw state.interruption }
            throw error
        }
    }
}
