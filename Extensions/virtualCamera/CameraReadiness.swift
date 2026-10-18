import AVFoundation

enum CameraReadiness: Equatable {
    case needsSetup(String)
    case unsupported(String)
    case ready(String)

    static func inspect(
        status: AVAuthorizationStatus = VirtualCameraDevices.authorization,
        cameraCount: (() -> Int)? = nil, extensionInstalled: (() -> Bool)? = nil
    ) -> CameraReadiness {
        switch status {
        case .authorized:
            let cameras = cameraCount?() ?? VirtualCameraDevices.sources().count
            guard cameras > 0 else { return .needsSetup("No camera is connected.") }
            let installed =
                extensionInstalled?()
                ?? VirtualCameraSink(
                    extensionIdentifier: VirtualCameraIdentity.extensionIdentifier(
                        forApplication: AppBuildIdentity.application)
                ).isInstalled
            guard installed else {
                return .needsSetup(
                    "Install the Edith Camera extension from the Virtual Camera page.")
            }
            let noun = cameras == 1 ? "camera" : "cameras"
            return .ready("Edith Camera is installed with \(cameras) \(noun) to frame.")
        case .notDetermined:
            return .needsSetup("Camera access has not been requested.")
        case .denied:
            return .needsSetup("Camera access is denied in System Settings.")
        case .restricted:
            return .unsupported("macOS does not allow Edith to use the camera.")
        @unknown default:
            return .unsupported("This macOS version returned an unknown camera access state.")
        }
    }

}
