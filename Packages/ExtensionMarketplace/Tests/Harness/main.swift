import ExtensionMarketplace
import Foundation

@main
struct MarketplaceHarness {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "verify-ui-carrier" {
            guard arguments.count == 3 else { throw MarketplaceError.invalidCatalog }
            let payload = URL(fileURLWithPath: arguments[1])
            let manifest = try JSONDecoder().decode(
                ExtensionPayloadManifest.self,
                from: Data(contentsOf: payload.appendingPathComponent("package.json")))
            let carrier = try ExtensionUICarrier(
                payload: payload, manifest: manifest, expectedHostIdentifier: arguments[2])
            try carrier.verifyDevelopment()
            print(
                "{\"identityValidated\":true,\"signatureVerified\":true,\"sandboxVerified\":true}")
            return
        }
        guard arguments.count >= 4 else { throw MarketplaceError.invalidCatalog }
        let operation = arguments[0]
        guard
            ["install", "update", "inspect", "queue-remove", "remove"].contains(operation)
        else {
            throw MarketplaceError.invalidCatalog
        }
        let store = ExtensionPackageStore(root: URL(fileURLWithPath: arguments[1]))
        let catalogURL = URL(string: arguments[2])!
        guard let key = Data(base64Encoded: arguments[3]) else {
            throw MarketplaceError.invalidSignature
        }
        let suite = "test.marketplace.harness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "keepAwakeEnabled")
        let client = ExtensionCatalogClient(
            url: catalogURL, publicKey: key, repository: "pulkitxm/edith",
            cache: store.root.appendingPathComponent("catalog.json")
        ) { url in
            if url.isFileURL { return try Data(contentsOf: url) }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw MarketplaceError.downloadFailed
            }
            return data
        }
        let downloads: [String: String]
        if let path = ProcessInfo.processInfo.environment["EXTENSION_FIXTURE_DOWNLOADS"] {
            downloads = try JSONDecoder().decode(
                [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            downloads = [:]
        }
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { url, _ in
                if let path = downloads[url.absoluteString] {
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
                        UUID().uuidString)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
                    return copy
                }
                let (file, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw MarketplaceError.downloadFailed
                }
                return file
            },
            verify: { directory in
                let manifest = try JSONDecoder().decode(
                    ExtensionPayloadManifest.self,
                    from: Data(contentsOf: directory.appendingPathComponent("package.json")))
                let carrier = try ExtensionUICarrier(payload: directory, manifest: manifest)
                try carrier.verifyDevelopment()
                for role in ExtensionBundleRuntime.Role.allCases {
                    let bundle = carrier.payloadDirectory.appendingPathComponent(
                        "\(role.rawValue).bundle")
                    if FileManager.default.fileExists(atPath: bundle.path) {
                        try ExtensionCodeSignature.verifyDevelopment(bundle)
                    }
                }
            })
        if operation == "remove" {
            try store.completePendingRemovals()
            print("{\"removed\":\(try store.installedPackages().isEmpty)}")
            return
        }
        if operation == "install" {
            let catalog = try await client.refresh().catalog
            _ = try await installer.install(
                catalog.installationPlan(
                    for: "keepAwake",
                    hostABI: MarketplaceConfiguration.workerHostABI,
                    architecture: "arm64",
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                repository: "pulkitxm/edith")
        }
        let runtime = ExtensionBundleRuntime(
            store: store, role: .helper, hostABI: MarketplaceConfiguration.workerHostABI,
            verify: ExtensionCodeSignature.verifyDevelopment)
        try runtime.start(id: "keepAwake", context: ["defaultsSuite": suite])
        let initial = try runtime.snapshot(id: "keepAwake")!
        if operation == "update" {
            let catalog = try await client.refresh().catalog
            _ = try await installer.install(
                catalog.installationPlan(
                    for: "keepAwake",
                    hostABI: MarketplaceConfiguration.workerHostABI,
                    architecture: "arm64",
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                repository: "pulkitxm/edith")
        }
        try runtime.stopAll()
        if operation == "queue-remove" {
            guard try store.requestRemoval(id: "keepAwake") == false else {
                throw MarketplaceError.invalidBundle
            }
        }
        let final = try runtime.snapshot(id: "keepAwake")!
        let output: [String: Any] = [
            "loadedVersion": initial.version, "activeAfterStop": final.active,
            "restartRequired": final.restartRequired,
            "installedVersion": try store.installedPackage(
                id: "keepAwake", hostABI: MarketplaceConfiguration.workerHostABI,
                architecture: "arm64")!
                .version,
        ]
        print(
            String(
                decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys),
                as: UTF8.self))
    }
}
