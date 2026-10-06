@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation

public struct VirtualCameraScreenSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
}

public enum VirtualCameraScreenCatalog {
    public static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    public static func windows(in content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            $0.frame.width > 100 && $0.frame.height > 100 && !($0.title ?? "").isEmpty
        }
    }

    public static func sources() async throws -> [VirtualCameraScreenSource] {
        let content = try await content()
        let displays = content.displays.enumerated().map { index, display in
            VirtualCameraScreenSource(
                id: "display:\(display.displayID)", name: "Display \(index + 1)", kind: "display")
        }
        return displays
            + windows(in: content).map { window in
                VirtualCameraScreenSource(
                    id: "window:\(window.windowID)",
                    name:
                        "\(window.owningApplication?.applicationName ?? "Window"): \(window.title ?? "")",
                    kind: "window")
            }
    }
}

public final class VirtualCameraScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private let queue: DispatchQueue
    private var stream: SCStream?
    private var audioStream: SCStream?
    private var configuration: VirtualCameraMedia?
    private var generation = 0
    private var frameHandler: ((CVPixelBuffer) -> Void)?
    private var audioHandler: ((CMSampleBuffer) -> Void)?
    private var failureHandler: ((String) -> Void)?

    public init(queue: DispatchQueue) { self.queue = queue }

    public func start(
        _ media: VirtualCameraMedia, size: CGSize, frameRate: Int,
        audio: ((CMSampleBuffer) -> Void)? = nil,
        failed: @escaping (String) -> Void, frame: @escaping (CVPixelBuffer) -> Void
    ) {
        guard configuration != media else { return }
        stop()
        configuration = media
        frameHandler = frame
        audioHandler = audio
        failureHandler = failed
        let generation = generation
        Task {
            do {
                let content = try await VirtualCameraScreenCatalog.content()
                let filter: SCContentFilter
                let audioFilter: SCContentFilter
                if let display = content.displays.first(where: {
                    media.screenID == "display:\($0.displayID)"
                }) {
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    audioFilter = filter
                } else if let window = content.windows.first(where: {
                    media.screenID == "window:\($0.windowID)"
                }) {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    guard let display = content.displays.first,
                        let application = window.owningApplication
                    else {
                        throw NSError(
                            domain: "MeetingScreen", code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "The selected window’s app is unavailable. Refresh sources."
                            ])
                    }
                    audioFilter = SCContentFilter(
                        display: display, including: [application], exceptingWindows: [])
                } else {
                    throw NSError(
                        domain: "MeetingScreen", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The selected screen or window is unavailable. Choose another source."
                        ])
                }
                let settings = SCStreamConfiguration()
                settings.width = Int(size.width)
                settings.height = Int(size.height)
                settings.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                settings.pixelFormat = kCVPixelFormatType_32BGRA
                settings.capturesAudio = false
                let stream = SCStream(filter: filter, configuration: settings, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                let audioStream: SCStream?
                if media.audioEnabled {
                    let settings = SCStreamConfiguration()
                    settings.width = 2
                    settings.height = 2
                    settings.minimumFrameInterval = CMTime(seconds: 60, preferredTimescale: 600)
                    settings.capturesAudio = true
                    settings.excludesCurrentProcessAudio = true
                    settings.sampleRate = 48000
                    settings.channelCount = 2
                    let capture = SCStream(
                        filter: audioFilter, configuration: settings, delegate: self)
                    try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                    try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                    audioStream = capture
                } else {
                    audioStream = nil
                }
                let accepted = await withCheckedContinuation { continuation in
                    queue.async { [weak self] in
                        guard let self, self.generation == generation else {
                            continuation.resume(returning: false); return
                        }
                        self.stream = stream
                        self.audioStream = audioStream
                        continuation.resume(returning: true)
                    }
                }
                guard accepted else { return }
                try await stream.startCapture()
                try await audioStream?.startCapture()
                queue.async { [weak self] in
                    guard let self else { return }
                    if self.generation != generation {
                        Task {
                            try? await stream.stopCapture(); try? await audioStream?.stopCapture()
                        }
                    }
                }
            } catch {
                queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.stop()
                    self.failureHandler?(error.localizedDescription)
                }
            }
        }
    }

    public func stop() {
        generation += 1
        if let stream { Task { try? await stream.stopCapture() } }
        if let audioStream { Task { try? await audioStream.stopCapture() } }
        stream = nil
        audioStream = nil
        configuration = nil
        frameHandler = nil
        audioHandler = nil
    }

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        if stream === audioStream, type == .audio { audioHandler?(sampleBuffer); return }
        guard stream === self.stream else { return }
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            status != SCFrameStatus.complete.rawValue
        {
            return
        }
        frameHandler?(buffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, stream === self.stream || stream === self.audioStream else { return }
            self.failureHandler?(error.localizedDescription)
        }
    }
}
