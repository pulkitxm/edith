import CoreMediaIO
import EdithCameraSupport
import Foundation
import os

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(bundle: Bundle) {
        super.init()
        let extensionIdentifier =
            bundle.bundleIdentifier
            ?? VirtualCameraIdentity.extensionIdentifier(
                forApplication: VirtualCameraIdentity.productionApplication)
        let application = VirtualCameraIdentity.application(forExtension: extensionIdentifier)
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        deviceSource = CameraDeviceSource(
            extensionIdentifier: extensionIdentifier,
            localizedName: VirtualCameraIdentity.deviceName(forApplication: application),
            build: build)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            Logger(subsystem: extensionIdentifier, category: "provider")
                .error("could not add the camera device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties
    {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = VirtualCameraIdentity.manufacturer
        }
        if properties.contains(.providerName) {
            providerProperties.name = VirtualCameraIdentity.productName
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
