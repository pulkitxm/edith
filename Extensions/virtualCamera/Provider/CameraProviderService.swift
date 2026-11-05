import CoreMediaIO
import EdithExtensionSupport
import Foundation

@MainActor final class CameraProviderService: ExtensionService {
    private var source: CameraProviderSource?

    var requiresDefaultsSuite: Bool { false }
    var isRunning: Bool { source != nil }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard source == nil, context.input["fixture"] as? Bool == false else { return false }
        let provider = CameraProviderSource(bundle: .main)
        source = provider
        CMIOExtensionProvider.startService(provider: provider.provider)
        return true
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "probe" else { return nil }
        return [
            "ok": context["fixture"] as? Bool == true
                && !VirtualCameraFormat.supported.compactMap(CameraDeviceSource.streamFormat)
                    .isEmpty,
            "payloadLoaded": true, "role": "cameraProvider", "providerServiceStarted": false,
        ] as NSDictionary
    }

    func teardown() async {
        guard let source else { return }
        if #available(macOS 14.4, *) {
            CMIOExtensionProvider.stopService(provider: source.provider)
        }
        source.shutdown()
        self.source = nil
    }
}

@MainActor
func makeCameraProviderRuntime(service: CameraProviderService? = nil) -> ExtensionServiceRuntime {
    let service = service ?? CameraProviderService()
    return ExtensionServiceRuntime(
        id: "virtualCamera", role: "cameraProvider",
        bundle: Bundle(for: CameraProviderService.self)
    ) { _ in service }
}
