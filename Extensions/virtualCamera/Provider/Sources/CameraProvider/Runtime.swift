import CoreMediaIO
import Foundation

@MainActor
final class CameraProviderRuntime: NSObject {
    private var source: CameraProviderSource?

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: Self.self)
            return [
                "id": "virtualCamera", "role": "cameraProvider",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard source == nil else { return ["ok": false] as NSDictionary }
            let provider = CameraProviderSource(bundle: .main)
            source = provider
            CMIOExtensionProvider.startService(provider: provider.provider)
        case "probe":
            guard input["fixture"] as? Bool == true else { return ["ok": false] as NSDictionary }
            return [
                "ok": !VirtualCameraFormat.supported.compactMap(CameraDeviceSource.streamFormat)
                    .isEmpty, "providerServiceStarted": false, "payloadLoaded": true,
                "role": "cameraProvider",
            ] as NSDictionary
        case "stop":
            if let source {
                if #available(macOS 14.4, *) {
                    CMIOExtensionProvider.stopService(provider: source.provider)
                }
                source.shutdown()
            }
            source = nil
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createCameraProvider() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(CameraProviderRuntime()).toOpaque())
        })
}
