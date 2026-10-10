import AVFoundation
import AppKit
import CoreImage
import EdithExtensionSupport
import Foundation

struct NotchCameraDevice: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
}

struct NotchCameraState: Codable, Sendable {
    let authorization: Int
    let devices: [NotchCameraDevice]
    let selectedID: String?
    let frame: Data?
    let error: String?
}

struct NotchCameraRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case read, start, select, permission, privacy, stop
    }
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let operation: Operation
    var deviceID: String? = nil
}

@MainActor protocol NotchCameraHardware: AnyObject {
    var authorization: Int { get }
    var devices: [NotchCameraDevice] { get }
    func permission() async -> Bool
    func start(deviceID: String?, frame: @escaping @Sendable (Data) -> Void) async throws
    func stop() async
    func privacy() throws
}

@MainActor final class NotchCameraEngine {
    private let hardware: any NotchCameraHardware
    private var generation = UUID()
    private var running = false
    private var stopped = false
    private var frame: Data?
    private var selectedID: String?
    private var failure: String?
    private var stopTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    var changed: (() -> Void)?
    init(hardware: any NotchCameraHardware) { self.hardware = hardware }
    func execute(_ request: NotchCameraRequest) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        switch request.operation {
        case .read: break
        case .permission:
            let token = generation
            let authorized = await hardware.permission()
            try Task.checkCancellation()
            guard !stopped, generation == token else { throw CancellationError() }
            if authorized { try await start(deviceID: nil) }
        case .privacy: try hardware.privacy()
        case .stop: stopCapture()
        case .start, .select:
            try await start(deviceID: request.deviceID)
        }
        return try JSONEncoder().encode(state())
    }
    private func start(deviceID: String?) async throws {
        guard hardware.authorization == AVAuthorizationStatus.authorized.rawValue,
            deviceID.map({ id in hardware.devices.contains { $0.id == id } }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        let chosen = deviceID ?? hardware.devices.first?.id
        guard chosen != nil else {
            throw ExtensionPeerError.rejected("No camera is available.")
        }
        stopCapture()
        let waitingToken = generation
        await stopTask?.value
        try Task.checkCancellation()
        guard !stopped, generation == waitingToken else { throw CancellationError() }
        selectedID = chosen
        generation = UUID()
        let token = generation
        running = true
        let hardware = hardware
        let selectedID = selectedID
        let task = Task { [weak self] in
            try await hardware.start(deviceID: selectedID) { [weak self] bytes in
                guard bytes.count <= 524288 else { return }
                Task { @MainActor [weak self] in
                    guard let self, !stopped, running, generation == token else { return }
                    frame = bytes; changed?()
                }
            }
        }
        startTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch { stopCapture(); throw error }
    }
    func state() throws -> NotchCameraState {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let devices =
            hardware.authorization == AVAuthorizationStatus.authorized.rawValue
            ? hardware.devices : []
        guard devices.count <= 32,
            devices.allSatisfy({ $0.id.utf8.count <= 256 && $0.name.utf8.count <= 1024 })
        else { throw ExtensionPeerError.invalidRequest }
        return .init(
            authorization: hardware.authorization, devices: devices, selectedID: selectedID,
            frame: frame, error: failure)
    }
    func stopCapture() {
        generation = UUID()
        guard running || startTask != nil else { return }
        running = false; frame = nil
        startTask?.cancel()
        let previous = stopTask
        let start = startTask
        startTask = nil
        let hardware = hardware
        stopTask = Task {
            await previous?.value
            _ = try? await start?.value
            await hardware.stop()
        }
    }
    func shutdown() { stopped = true; changed = nil; stopCapture() }
    func shutdownAndWait() async { shutdown(); await stopTask?.value }
}

@MainActor final class NativeNotchCameraHardware: NotchCameraHardware {
    private let owner = NotchCameraCaptureOwner()
    var authorization: Int { AVCaptureDevice.authorizationStatus(for: .video).rawValue }
    var devices: [NotchCameraDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video,
            position: .unspecified
        ).devices.map { .init(id: $0.uniqueID, name: $0.localizedName) }
    }
    func permission() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
    func start(deviceID: String?, frame: @escaping @Sendable (Data) -> Void) async throws {
        try await owner.start(deviceID: deviceID, frame: frame)
    }
    func stop() async { await owner.stop() }
    func privacy() throws {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"),
            NSWorkspace.shared.open(url)
        else { throw ExtensionPeerError.unavailable }
    }
}

private final class NotchCameraCaptureOwner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "edith.notch.camera.capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext()
    private var receive: (@Sendable (Data) -> Void)?
    private var lastFrame: TimeInterval = 0
    func start(deviceID: String?, frame: @escaping @Sendable (Data) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) else {
                        throw ExtensionPeerError.unavailable
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    session.sessionPreset = .medium
                    for old in session.inputs { session.removeInput(old) }
                    for old in session.outputs { session.removeOutput(old) }
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration(); throw ExtensionPeerError.unavailable
                    }
                    session.addInput(input)
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.addOutput(output)
                    session.commitConfiguration()
                    receive = frame
                    session.startRunning()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                receive = nil
                session.stopRunning()
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.1, let receive,
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastFrame = now
        let image = CIImage(cvPixelBuffer: buffer)
        guard
            let data = context.jpegRepresentation(
                of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [
                    CIImageRepresentationOption(
                        rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.75
                ]), data.count <= 524288
        else { return }
        receive(data)
    }
}
