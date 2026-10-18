import Foundation

public struct HostStoragePackageScopes: Sendable {
    public let scopes: [HostStorageScope]
    public let executableScopeIDs: [String]
    public let frameworkScopeIDs: [String]

    public init(key: String, directory: URL, extensionID: String, roles: [String]) {
        let carrier = directory.appendingPathComponent(
            extensionID + "/ExtensionCarrier.app/Contents")
        let worker = carrier.appendingPathComponent("Extensions/ExtensionWorker.appex/Contents")
        let payload = worker.appendingPathComponent("Resources/Payload/" + extensionID)
        let camera = directory.appendingPathComponent(extensionID + "/CameraCarrier.app/Contents")
        let bundles =
            [("carrier", carrier), ("worker", worker)]
            + roles.map { ("role:" + $0, payload.appendingPathComponent($0 + ".bundle/Contents")) }
            + [("camera-carrier", camera)]
            + ["cameraCarrier", "privileged"].map {
                (
                    "camera-carrier:role:" + $0,
                    camera.appendingPathComponent("PlugIns/" + $0 + ".bundle/Contents")
                )
            }
        executableScopeIDs = bundles.map { key + ":" + $0.0 + ":executable" }
        frameworkScopeIDs = bundles.map { key + ":" + $0.0 + ":frameworks" }
        scopes =
            [.init(id: key, root: directory, expected: true)]
            + zip(executableScopeIDs, bundles).map { id, bundle in
                .init(id: id, root: bundle.1.appendingPathComponent("MacOS"))
            }
            + zip(frameworkScopeIDs, bundles).map { id, bundle in
                .init(id: id, root: bundle.1.appendingPathComponent("Frameworks"))
            }
    }
}

public struct HostStorageDataScopes: Sendable {
    public let scopes: [HostStorageScope]
    public let ownedIDs: [String: [String]]
    public let sharedIDs: [String: [String]]
    public let sharedScopeIDs: [String]

    public init(scopes: [HostStorageScope], owners: [String: [String]]) {
        let dataIDs = Set(owners.values.flatMap { $0 })
        let groups = Dictionary(grouping: scopes.filter { dataIDs.contains($0.id) }) {
            $0.root.standardizedFileURL.path
        }
        var replacements: [String: String] = [:]
        var shared: [HostStorageScope] = []
        for path in groups.keys.sorted() {
            let group = groups[path]!.sorted { $0.id < $1.id }
            let claimingOwners = owners.keys.filter { owner in
                group.contains { owners[owner]!.contains($0.id) }
            }
            guard claimingOwners.count > 1 else { continue }
            let id = "shared:" + group[0].id
            shared.append(.init(id: id, root: group[0].root))
            for scope in group { replacements[scope.id] = id }
        }
        self.scopes = scopes.filter { replacements[$0.id] == nil } + shared
        ownedIDs = owners.mapValues { $0.filter { replacements[$0] == nil } }
        sharedIDs = owners.mapValues {
            Array(Set($0.compactMap { replacements[$0] })).sorted()
        }
        sharedScopeIDs = shared.map(\.id)
    }
}
