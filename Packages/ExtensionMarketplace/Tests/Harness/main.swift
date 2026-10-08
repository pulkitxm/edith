import ExtensionMarketplace
import Foundation

@main
struct MarketplaceHarness {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 4 else { throw MarketplaceError.invalidCatalog }
        let operation = arguments[0]
        guard
            ["install", "update", "inspect", "queue-remove", "remove", "voice"].contains(operation)
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
                for bundle in try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
                where bundle.pathExtension == "bundle" {
                    try ExtensionCodeSignature.verifyDevelopment(bundle)
                }
            })
        if operation == "remove" {
            try store.completePendingRemovals()
            print("{\"removed\":\(try store.installedPackages().isEmpty)}")
            return
        }
        if operation == "install" || operation == "voice" {
            let catalog = try await client.refresh().catalog
            _ = try await installer.install(
                catalog.installationPlan(
                    for: operation == "voice" ? "audioMixer" : "keepAwake",
                    hostABI: MarketplaceConfiguration.hostABI,
                    architecture: "arm64",
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                repository: "pulkitxm/edith")
        }
        if operation == "voice" {
            let library = try ExtensionNativeLibrary.load(
                id: "audioMixer", store: store,
                hostABI: MarketplaceConfiguration.hostABI,
                verify: ExtensionCodeSignature.verifyDevelopment)
            typealias Create =
                @convention(c) (
                    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int
                ) -> UnsafeMutableRawPointer?
            let create = try library.symbol("MeetingVoiceCreate", as: Create.self)
            var error = [CChar](repeating: 0, count: 2048)
            guard
                create(
                    "/synthetic/missing-encoder.onnx", "/synthetic/missing-voice.onnx", &error,
                    error.count) == nil,
                error.first != 0
            else { throw MarketplaceError.invalidBundle }
            print("{\"nativeVoiceRuntime\":\"loaded\",\"missingModelRejected\":true}")
            return
        }
        let runtime = ExtensionBundleRuntime(
            store: store, role: .helper, hostABI: MarketplaceConfiguration.hostABI,
            verify: ExtensionCodeSignature.verifyDevelopment)
        try runtime.start(id: "keepAwake", context: ["defaultsSuite": suite])
        let initial = try runtime.snapshot(id: "keepAwake")!
        if operation == "update" {
            let catalog = try await client.refresh().catalog
            _ = try await installer.install(
                catalog.installationPlan(
                    for: operation == "voice" ? "audioMixer" : "keepAwake",
                    hostABI: MarketplaceConfiguration.hostABI,
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
                id: "keepAwake", hostABI: MarketplaceConfiguration.hostABI, architecture: "arm64")!
                .version,
        ]
        print(
            String(
                decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys),
                as: UTF8.self))
    }
}
