@preconcurrency import AVFoundation
import EdithCameraSupport
import EdithCore
import Foundation

public struct VirtualCameraSource: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case builtIn
        case continuity
        case external
        case deskView
        case virtual
    }

    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var symbolName: String {
        switch kind {
        case .builtIn: "laptopcomputer"
        case .continuity: "iphone"
        case .external: "web.camera"
        case .deskView: "rectangle.and.hand.point.up.left"
        case .virtual: "camera.filters"
        }
    }
}

public struct VirtualCameraFormatOption: Equatable, Sendable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let maxFrameRate: Double

    public init(index: Int, width: Int, height: Int, maxFrameRate: Double) {
        self.index = index
        self.width = width
        self.height = height
        self.maxFrameRate = maxFrameRate
    }
}

public enum VirtualCameraFormatChooser {
    public static func choose(
        _ options: [VirtualCameraFormatOption], minimumWidth: Int, frameRate: Double
    ) -> VirtualCameraFormatOption? {
        let fast = options.filter { $0.maxFrameRate + 0.5 >= frameRate }
        let pool = fast.isEmpty ? options : fast
        let wideEnough = pool.filter { $0.width >= minimumWidth }
        if let smallest = wideEnough.min(by: {
            area($0) < area($1) || (area($0) == area($1) && $0.maxFrameRate > $1.maxFrameRate)
        }) {
            return smallest
        }
        return pool.max {
            area($0) < area($1) || (area($0) == area($1) && $0.maxFrameRate < $1.maxFrameRate)
        }
    }

    static func area(_ option: VirtualCameraFormatOption) -> Int {
        option.width * option.height
    }
}

public enum VirtualCameraDevices {
    public static var ownExtensionIdentifiers: [String] {
        let application = AppBuildIdentity.application
        let production = VirtualCameraIdentity.productionApplication
        return [application, production].map {
            VirtualCameraIdentity.extensionIdentifier(forApplication: $0)
        }
    }

    public static var ownDeviceIDs: Set<String> {
        Set(
            ownExtensionIdentifiers.map {
                VirtualCameraIdentity.deviceID(forExtension: $0).uuidString
            })
    }

    static var deviceTypes: [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        types.append(.continuityCamera)
        types.append(.deskViewCamera)
        return types
    }

    public static func captureDevices() -> [AVCaptureDevice] {
        let excluded = ownDeviceIDs
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .video, position: .unspecified
        ).devices.filter { device in
            !excluded.contains(device.uniqueID)
                && !device.localizedName.hasPrefix(VirtualCameraIdentity.productName)
        }
    }

    public static func sources() -> [VirtualCameraSource] {
        captureDevices().map(source(for:))
    }

    public static func source(for device: AVCaptureDevice) -> VirtualCameraSource {
        VirtualCameraSource(id: device.uniqueID, name: device.localizedName, kind: kind(of: device))
    }

    static func kind(of device: AVCaptureDevice) -> VirtualCameraSource.Kind {
        switch device.deviceType {
        case .builtInWideAngleCamera: return .builtIn
        case .continuityCamera: return .continuity
        case .deskViewCamera: return .deskView
        default:
            return device.transportType == 0x7669_7274 ? .virtual : .external
        }
    }

    public static func device(for id: String?) -> AVCaptureDevice? {
        let devices = captureDevices()
        if let id, let match = devices.first(where: { $0.uniqueID == id }) { return match }
        return preferredDefault(in: devices)
    }

    static func preferredDefault(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first { $0.deviceType == .continuityCamera }
            ?? devices.first
    }

    public static func formatOptions(for device: AVCaptureDevice) -> [VirtualCameraFormatOption] {
        device.formats.enumerated().compactMap { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else { return nil }
            let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return VirtualCameraFormatOption(
                index: index, width: Int(dimensions.width), height: Int(dimensions.height),
                maxFrameRate: rate)
        }
    }

    public static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }
}
