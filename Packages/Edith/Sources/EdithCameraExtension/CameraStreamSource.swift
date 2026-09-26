import CoreMedia
import CoreMediaIO
import EdithCameraSupport
import Foundation

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private weak var owner: CameraDeviceSource?
    private let streamFormats: [CMIOExtensionStreamFormat]
    private let direction: CMIOExtensionStream.Direction
    private var pendingClient: CMIOExtensionClient?

    init(
        localizedName: String, streamID: UUID, direction: CMIOExtensionStream.Direction,
        formats: [CMIOExtensionStreamFormat], owner: CameraDeviceSource
    ) {
        self.owner = owner
        self.streamFormats = formats
        self.direction = direction
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: direction,
            clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [
            .streamActiveFormatIndex, .streamFrameDuration,
        ]
        if direction == .sink {
            properties.formUnion([
                .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
            ])
        } else {
            properties.insert(CameraDeviceSource.statusProperty)
        }
        return properties
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        let format = owner?.activeFormat ?? .standard
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = VirtualCameraFormat.index(of: format) ?? 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(
                value: 1, timescale: CMTimeScale(format.frameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        if properties.contains(CameraDeviceSource.statusProperty), let owner {
            streamProperties.setPropertyState(
                owner.statusState(), forProperty: CameraDeviceSource.statusProperty)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            owner?.selectFormat(at: index)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if direction == .sink {
            pendingClient = client
        }
        return true
    }

    func startStream() throws {
        if direction == .sink {
            guard let client = pendingClient else { return }
            owner?.sinkStarted(client: client)
        } else {
            owner?.consumersChanged()
        }
    }

    func stopStream() throws {
        if direction == .sink {
            pendingClient = nil
            owner?.sinkStopped()
        } else {
            owner?.consumersChanged()
        }
    }
}
