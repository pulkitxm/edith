import AVFoundation
import AppKit
import SwiftUI

struct NotchCameraTab: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch status {
            case .authorized:
                CameraPreview()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 14).padding(.bottom, 12)
            case .notDetermined:
                prompt("Enable the camera") {
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        Task { @MainActor in
                            status = granted ? .authorized : .denied
                        }
                    }
                }
            default:
                denied
            }
        }
    }

    private func prompt(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "camera.fill").font(.system(size: 20))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private var denied: some View {
        Button {
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            {
                NSWorkspace.shared.open(url)
            }
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
        .buttonStyle(.plain).pointerCursor()
    }
}

private struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView() }
    func updateNSView(_ nsView: CameraPreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: ()) { nsView.stop() }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.pulkit.edith.notch.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?

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
            let device =
                AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async {
                if let connection = preview.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
}
