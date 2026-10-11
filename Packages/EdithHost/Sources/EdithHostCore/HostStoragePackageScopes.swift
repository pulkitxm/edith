import Foundation

public struct HostStoragePackageScopes: Sendable {
    public let scopes: [HostStorageScope]
    public let executableScopeIDs: [String]
    public let frameworkScopeIDs: [String]

    public init(key: String, directory: URL, extensionID: String, roles: [String]) {
        let carrier = directory.appendingPathComponent(extensionID + "/ExtensionCarrier.app/Contents")
        let worker = carrier.appendingPathComponent("Extensions/ExtensionWorker.appex/Contents")
        let payload = worker.appendingPathComponent("Resources/Payload/" + extensionID)
        let camera = directory.appendingPathComponent(extensionID + "/CameraCarrier.app/Contents")
        let bundles = [("carrier", carrier), ("worker", worker)]
            + roles.map { ("role:" + $0, payload.appendingPathComponent($0 + ".bundle/Contents")) }
            + [("camera-carrier", camera)]
            + ["cameraCarrier", "privileged"].map {
                ("camera-carrier:role:" + $0, camera.appendingPathComponent("PlugIns/" + $0 + ".bundle/Contents"))
            }
        executableScopeIDs = bundles.map { key + ":" + $0.0 + ":executable" }
        frameworkScopeIDs = bundles.map { key + ":" + $0.0 + ":frameworks" }
        scopes = [.init(id: key, root: directory, expected: true)]
            + zip(executableScopeIDs, bundles).map { id, bundle in
                .init(id: id, root: bundle.1.appendingPathComponent("MacOS"))
            }
            + zip(frameworkScopeIDs, bundles).map { id, bundle in
                .init(id: id, root: bundle.1.appendingPathComponent("Frameworks"))
            }
    }
}
