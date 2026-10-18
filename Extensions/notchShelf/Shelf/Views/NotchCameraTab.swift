import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchCameraTab: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var devices: [AVCaptureDevice] = []
    @State private var selectedID: String?

    var body: some View {
        Group {
            switch status {
            case .authorized:
                CameraPreview(
                    deviceID: selectedID, covered: NotchPresenterState.shared.hides(.camera)
                )

                .overlay(alignment: .bottomTrailing) {
                    if devices.count > 1 {
                        switchButton
                    }
                }
                .onAppear(perform: refreshDevices)
            case .notDetermined:
                prompt {
                    AVCaptureDevice.requestAccess(for: .video) { _ in
                        Task { @MainActor in
                            status = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                    }
                }
            default:
                denied
            }
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name(NotchWorkerIPC.Name.permissionsRefreshed))
        ) { _ in
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private var switchButton: some View {
        Button(action: cycleCamera) {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.edith(.borderless))
        .padding(14)
        .help("Switch camera")
    }

    private func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        devices = discovery.devices
        if selectedID == nil { selectedID = devices.first?.uniqueID }
    }

    private func cycleCamera() {
        guard devices.count > 1 else { return }
        let ids = devices.map(\.uniqueID)
        let index = ids.firstIndex(of: selectedID ?? "") ?? 0
        selectedID = ids[(index + 1) % ids.count]
    }

    private func prompt(action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill").font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.7))
            Text("Mirror check, right in the notch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("macOS asks for camera access once. Nothing is recorded or sent anywhere.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 8) {
                Button("Allow Camera", action: action)
                    .buttonStyle(.edith(.primary))
                    .controlSize(.small)
                Button("All Permissions") {
                    NotchWorkerPresentation.openPrivacySettings()
                }
                .buttonStyle(.edith(.borderless))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var denied: some View {
        Button {
            NotchWorkerPresentation.openPrivacySettings()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "camera.metering.none").font(.system(size: 20))
                Text("Camera access is off").font(.system(size: 12))
                Text("Open System Settings").font(.system(size: 10)).foregroundStyle(
                    .white.opacity(0.5))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.edith(.borderless))
    }
}

private struct CameraPreview: NSViewRepresentable {
    var deviceID: String?
    var covered = false

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.setDevice(deviceID)
        view.setCovered(covered)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.setDevice(deviceID)
        nsView.setCovered(covered)
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: ()) { nsView.stop() }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.pulkit.edith.notch.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentDeviceID: String?
    private var covered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        configure()
    }

    required init?(coder: NSCoder) { nil }

    private func configure() {
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(preview)
        previewLayer = preview

        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .medium
            self.session.commitConfiguration()
        }
    }

    func setCovered(_ covered: Bool) {
        previewLayer?.isHidden = covered
        queue.async { [weak self] in
            guard let self else { return }
            self.covered = covered
            if covered {
                self.session.stopRunning()
            } else if !self.session.inputs.isEmpty {
                self.session.startRunning()
            }
        }
    }

    func setDevice(_ id: String?) {
        guard id != currentDeviceID || session.inputs.isEmpty else { return }
        currentDeviceID = id
        let preview = previewLayer
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            let device =
                id.flatMap { AVCaptureDevice(uniqueID: $0) }
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
            if !self.covered { self.session.startRunning() }
            DispatchQueue.main.async {
                if let connection = preview?.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
    }

    func stop() {
        let session = session
        queue.async {
            session.stopRunning()
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
}
