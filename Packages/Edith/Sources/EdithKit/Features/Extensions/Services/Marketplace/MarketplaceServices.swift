import EdithCore
import ExtensionMarketplace
import Foundation

public enum MarketplaceServices {
    public static let downloadableIDs: Set<String> = [
        "keepAwake", "audioMixer", "focusDim", "windowSweaters", "micMute", "keystrokeHighlight",
        "presenter", "colorPicker", "systemStats",
    ]
    public static var store: ExtensionPackageStore {
        ExtensionPackageStore(
            root: AppDirectories.current.configuration.appendingPathComponent("Extensions"))
    }

    public static var catalogClient: ExtensionCatalogClient {
        let preview =
            AppBuildIdentity.isDevelopment
            ? ProcessInfo.processInfo.environment["EDITH_EXTENSION_CATALOG_URL"].flatMap(
                URL.init(string:))
            : nil
        return .live(
            cache: store.root.appendingPathComponent("catalog.json"),
            url: preview ?? MarketplaceConfiguration.catalogURL)
    }

    public static func installedPackage(id: String) -> ExtensionPackage? {
        guard (try? store.pendingRemovals().contains(id)) != true else { return nil }
        return try? store.installedPackage(
            id: id, hostABI: MarketplaceConfiguration.hostABI, architecture: "arm64")
    }

    public static func ensureInstalled(id: String) async throws {
        guard downloadableIDs.contains(id) else { return }
        guard try !store.pendingRemovals().contains(id) else {
            throw MarketplaceError.packageBusy
        }
        if installedPackage(id: id) != nil { return }
        let catalog = try await catalogClient.refresh().catalog
        _ = try await installer.install(
            catalog.installationPlan(
                for: id, hostABI: MarketplaceConfiguration.hostABI,
                architecture: "arm64",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            repository: MarketplaceConfiguration.repository)
    }

    @MainActor public static let helperRuntime = ExtensionBundleRuntime(
        store: store, role: .helper, hostABI: MarketplaceConfiguration.hostABI,
        verify: verifyBundle)

    public static func verifyBundle(_ url: URL) throws {
        if AppBuildIdentity.isDevelopment {
            try ExtensionCodeSignature.verifyDevelopment(url)
        } else {
            guard let team = ExtensionCodeSignature.teamIdentifier() else {
                throw MarketplaceError.invalidSignature
            }
            try ExtensionCodeSignature.verify(url, teamIdentifier: team)
        }
    }

    public static var installer: ExtensionPackageInstaller {
        ExtensionPackageInstaller(
            store: store,
            download: { url, expectedBytes in
                let (file, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                    try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(expectedBytes)
                else {
                    try? FileManager.default.removeItem(at: file)
                    throw MarketplaceError.downloadFailed
                }
                return file
            },
            verify: { directory in
                for bundle in try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
                where bundle.pathExtension == "bundle" {
                    try verifyBundle(bundle)
                }
            })
    }
}
