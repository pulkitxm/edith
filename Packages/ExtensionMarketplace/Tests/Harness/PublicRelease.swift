import CryptoKit
import Darwin
import ExtensionMarketplace
import Foundation

private struct PublicReleaseRequest: Decodable, Sendable {
    let catalog: String
    let publicKey: String
    let teamIdentifier: String
    let current: [ExtensionPackage]
    let previous: [ExtensionPackage]
    let archives: [String: String]
    let updateIDs: [String]
    let root: String
    let sourceCommit: String
    let workflowCommit: String
}

private enum PublicInstallerFailure: Error {
    case rejected
}

private func requirePublic(_ condition: Bool) throws {
    guard condition else { throw PublicInstallerFailure.rejected }
}

private func privatePublicData(_ path: String, maximum: Int) throws -> Data {
    let url = URL(fileURLWithPath: path)
    try requirePublic(url.standardizedFileURL.path == path && url.resolvingSymlinksInPath().path == path)
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    try requirePublic(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    var before = stat()
    try requirePublic(fstat(descriptor, &before) == 0)
    try requirePublic(
        before.st_mode & S_IFMT == S_IFREG && before.st_uid == getuid()
            && before.st_mode & 0o7777 == 0o600 && before.st_nlink == 1
            && before.st_size > 0 && before.st_size <= maximum)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
    try requirePublic(bytes.count == before.st_size && bytes.count <= maximum)
    var after = stat()
    var current = stat()
    try requirePublic(fstat(descriptor, &after) == 0 && lstat(path, &current) == 0)
    func same(_ value: stat) -> Bool {
        value.st_dev == before.st_dev && value.st_ino == before.st_ino
            && value.st_uid == before.st_uid && value.st_mode == before.st_mode
            && value.st_nlink == before.st_nlink && value.st_size == before.st_size
            && value.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && value.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
            && value.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec
            && value.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    }
    try requirePublic(same(after) && same(current))
    return bytes
}

extension MarketplaceHarness {
    static func verifyPublicRelease(_ path: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        for (key, value) in [
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_OS": "macOS", "GITHUB_REPOSITORY": "pulkitxm/edith",
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
            "PUBLIC_RELEASE_VERIFICATION": "1", "PUBLISH": "false", "REBUILD": "",
        ] {
            try requirePublic(environment[key] == value)
        }
        try requirePublic(["65671483", "320458784"].contains(environment["GITHUB_ACTOR_ID"] ?? ""))
        let request = try JSONDecoder().decode(
            PublicReleaseRequest.self, from: privatePublicData(path, maximum: 4 * 1024 * 1024))
        try requirePublic(
            request.workflowCommit == environment["GITHUB_SHA"]
                && request.workflowCommit == environment["EXPECTED_SOURCE_SHA"]
                && request.sourceCommit.count == 40
                && request.sourceCommit.allSatisfy({ $0.isHexDigit && !$0.isUppercase }))
        let root = URL(fileURLWithPath: request.root)
        let authority = root.deletingLastPathComponent()
        try requirePublic(authority.resolvingSymlinksInPath().path == authority.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: authority.path)
        try requirePublic(
            attributes[.ownerAccountID] as? UInt32 == getuid()
                && attributes[.posixPermissions] as? Int == 0o700)
        for key in ["HOME", "CFFIXED_USER_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "TMPDIR"] {
            guard let value = environment[key] else { throw PublicInstallerFailure.rejected }
            try requirePublic(URL(fileURLWithPath: value).deletingLastPathComponent() == authority)
        }
        try requirePublic(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let packageRoot = root.appendingPathComponent("packages")
        let store = ExtensionPackageStore(root: packageRoot)
        let dataRoot = root.appendingPathComponent("support/Edith")
        let seeds: [String: Data] = [
            "data/usage.json": Data(#"{"history":[{"provider":"synthetic","tokens":37}]}"#.utf8),
            "data/usage.sqlite": Data([0, 1, 2, 255, 17, 0, 83]),
            "data/usage.sqlite-wal": Data([55, 127, 6, 130, 0, 254, 31]),
            "data/usage.sqlite-shm": Data([0, 19, 0, 128, 7]),
            "Core/Commands/Tasks/00000000-0000-0000-0000-000000000001.json": Data(
                #"{"title":"synthetic retained task","state":"completed"}"#.utf8),
            "Core/agent.json": Data(#"{"events":[{"message":"synthetic retained event"}]}"#.utf8),
            "Core/schedules.json": Data(#"{"schedules":[{"task":"synthetic","enabled":false}]}"#.utf8),
            "machines/companion-config.json": Data(#"{"provider":"synthetic","enabled":true}"#.utf8),
            "provider-hook-ownership.json": Data(#"{"provider":"synthetic","owned":false}"#.utf8),
        ]
        for (name, bytes) in seeds {
            let file = dataRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        var preservationChecks = 0
        func preserve() throws {
            for (name, expected) in seeds {
                let actual = try Data(contentsOf: dataRoot.appendingPathComponent(name))
                try requirePublic(actual == expected && SHA256.hash(data: actual) == SHA256.hash(data: expected))
            }
            preservationChecks += 1
        }
        let envelope = try privatePublicData(request.catalog, maximum: 3 * 1024 * 1024)
        guard let key = Data(base64Encoded: request.publicKey) else {
            throw PublicInstallerFailure.rejected
        }
        let catalog = try JSONDecoder().decode(SignedExtensionCatalog.self, from: envelope)
            .verified(publicKey: key, repository: MarketplaceConfiguration.repository)
        try requirePublic(request.current.count == 39 && request.previous.count == request.updateIDs.count)
        try requirePublic(Set(request.current.map(\.id)).count == 39)
        try requirePublic(Set(request.previous.map(\.id)) == Set(request.updateIDs) && Set(request.updateIDs).isSubset(of: Set(request.current.map(\.id))))
        try requirePublic(request.current.allSatisfy({ catalog.packages.contains($0) }))
        try requirePublic(request.previous.allSatisfy({ catalog.packages.contains($0) }))
        for previous in request.previous {
            guard let current = request.current.first(where: { $0.id == previous.id }) else {
                throw PublicInstallerFailure.rejected
            }
            try requirePublic(
                previous.hostABI == current.hostABI && previous.architecture == current.architecture
                    && previous.version.compare(current.version, options: .numeric) == .orderedAscending
                    && previous.sha256 != current.sha256)
        }
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { url, expectedBytes in
                guard let path = request.archives[url.absoluteString] else {
                    throw MarketplaceError.downloadFailed
                }
                let bytes = try privatePublicData(path, maximum: 512 * 1024 * 1024)
                try requirePublic(bytes.count == expectedBytes)
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try bytes.write(to: copy, options: .withoutOverwriting)
                return copy
            },
            verify: { directory in
                let manifest = try JSONDecoder().decode(
                    ExtensionPayloadManifest.self,
                    from: Data(contentsOf: directory.appendingPathComponent("package.json")))
                let carrier = try ExtensionUICarrier(
                    payload: directory, manifest: manifest, expectedHostIdentifier: "com.pulkit.edith")
                try carrier.verify(teamIdentifier: request.teamIdentifier)
                for role in ExtensionBundleRuntime.Role.allCases {
                    let bundle = carrier.payloadDirectory.appendingPathComponent("\(role.rawValue).bundle")
                    if FileManager.default.fileExists(atPath: bundle.path) {
                        try ExtensionCodeSignature.verify(bundle, teamIdentifier: request.teamIdentifier)
                    }
                }
                let camera = directory.appendingPathComponent("CameraCarrier.app")
                if FileManager.default.fileExists(atPath: camera.path) {
                    try ExtensionCodeSignature.verify(camera, teamIdentifier: request.teamIdentifier)
                }
            })
        _ = try await installer.install(request.previous, repository: MarketplaceConfiguration.repository)
        for package in request.previous { try store.select(package) }
        try preserve()
        _ = try await installer.install(request.current, repository: MarketplaceConfiguration.repository)
        try preserve()
        for package in request.current {
            try store.select(package)
            try requirePublic(try store.installedPackage(
                id: package.id, hostABI: package.hostABI, architecture: package.architecture) == package)
        }
        try preserve()
        let cache = root.appendingPathComponent("catalog-cache.json")
        let client = ExtensionCatalogClient(
            url: URL(string: "https://github.com/pulkitxm/edith/releases/download/extension-catalog-v1/catalog.json")!,
            publicKey: key, repository: MarketplaceConfiguration.repository, cache: cache,
            fetch: { _ in envelope })
        let online = try await client.refresh()
        try requirePublic(!online.offline && online.catalog == catalog)
        let offline = ExtensionCatalogClient(
            url: URL(string: "https://github.com/pulkitxm/edith/releases/download/extension-catalog-v1/catalog.json")!,
            publicKey: key, repository: MarketplaceConfiguration.repository, cache: cache,
            fetch: { _ in throw MarketplaceError.downloadFailed })
        let cached = try await offline.refresh()
        try requirePublic(cached.offline && cached.catalog == catalog)
        _ = try await installer.install(request.current, repository: MarketplaceConfiguration.repository)
        try preserve()
        var remaining = Set(request.current.map(\.id))
        while !remaining.isEmpty {
            guard let id = remaining.sorted().first(where: { id in
                !request.current.contains { remaining.contains($0.id) && $0.dependencies.contains(id) }
            }), let package = request.current.first(where: { $0.id == id }) else {
                throw MarketplaceError.invalidCatalog
            }
            let lease = try store.lease(package)
            defer { lease.close() }
            try requirePublic(try store.requestRemoval(id: id) == false)
            try requirePublic(try store.pendingRemovals().contains(id))
            try store.completePendingRemovals()
            try requirePublic(FileManager.default.fileExists(atPath: store.directory(for: package).path))
            lease.close()
            try store.completePendingRemovals()
            try requirePublic(!FileManager.default.fileExists(atPath: store.directory(for: package).path))
            try requirePublic(try store.installedPackages().allSatisfy({ $0.id != id }))
            try requirePublic(try !store.pendingRemovals().contains(id))
            try preserve()
            remaining.remove(id)
        }
        try requirePublic(try store.installedPackages().isEmpty)
        for package in request.previous {
            try requirePublic(!FileManager.default.fileExists(atPath: store.directory(for: package).path))
        }
        try preserve()
        let result: [String: Any] = [
            "schema": 1, "sourceCommit": request.sourceCommit, "owners": 39,
            "installationVerified": true, "publicVersionUpdateVerified": !request.updateIDs.isEmpty, "updatedIDs": request.updateIDs,
            "offlineCatalogAndSelectionVerified": true, "removalVerified": true,
            "busyRemovalAndLeaseDrainVerified": true, "persistentSyntheticDataPreserved": true,
            "preservationChecks": preservationChecks, "productionSignaturesVerified": true,
            "storeSelectionVerified": true, "workerEnableDisableExecuted": false,
            "workerProcessesStarted": 0, "featureCodeExecuted": false,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }
}
