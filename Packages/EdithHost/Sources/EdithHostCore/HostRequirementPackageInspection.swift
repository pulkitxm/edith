import ExtensionMarketplace
import Foundation

public struct HostRequirementPackageInspection: Sendable {
    public enum SignaturePolicy: Sendable { case publisher(teamIdentifier: String), development }
    private let store: ExtensionPackageStore
    private let hostABI: String
    private let architecture: String
    private let systemVersion: Int
    private let hostIdentifier: String
    private let requiredRoles: Set<String>
    private let verify: @Sendable (ExtensionUICarrier, [URL]) throws -> Void

    public init(
        store: ExtensionPackageStore, hostABI: String, architecture: String,
        systemVersion: Int, hostIdentifier: String, requiredRoles: Set<String>,
        policy: SignaturePolicy
    ) {
        self.init(
            store: store, hostABI: hostABI, architecture: architecture,
            systemVersion: systemVersion, hostIdentifier: hostIdentifier,
            requiredRoles: requiredRoles,
            verify: { carrier, bundles in
                switch policy {
                case let .publisher(team):
                    try carrier.verify(teamIdentifier: team)
                    for bundle in bundles {
                        try ExtensionCodeSignature.verify(bundle, teamIdentifier: team)
                    }
                case .development:
                    try carrier.verifyDevelopment()
                    for bundle in bundles { try ExtensionCodeSignature.verifyDevelopment(bundle) }
                }
            })
    }

    init(
        store: ExtensionPackageStore, hostABI: String, architecture: String,
        systemVersion: Int, hostIdentifier: String, requiredRoles: Set<String>,
        verify: @escaping @Sendable (ExtensionUICarrier, [URL]) throws -> Void
    ) {
        self.store = store; self.hostABI = hostABI; self.architecture = architecture
        self.requiredRoles = requiredRoles
        self.systemVersion = systemVersion; self.hostIdentifier = hostIdentifier;
        self.verify = verify
    }

    public func inspect(id: String, enabled: Bool, active: Bool) throws
        -> HostRequirementPackageState
    {
        _ = try HostExtensionRequirementCatalog.entry(id: id)
        try Task.checkCancellation()
        do {
            guard try !store.pendingRemovals().contains(id) else {
                return .invalid("The installed package is pending removal.")
            }
            guard try store.installedPackages().contains(where: { $0.id == id }) else {
                return .absent
            }
            guard
                let package = try store.installedPackage(
                    id: id, hostABI: hostABI,
                    architecture: architecture, systemVersion: systemVersion)
            else { return .incompatible }
            let payload = store.directory(for: package).appendingPathComponent(id)
            let carrier = try ExtensionUICarrier(
                payload: payload, package: package,
                expectedHostIdentifier: hostIdentifier)
            let bundles = try FileManager.default.contentsOfDirectory(
                at: carrier.payloadDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "bundle" }
            guard !requiredRoles.isEmpty,
                requiredRoles.isSubset(of: ["app", "helper", "agent", "cli", "privileged"]),
                Set(bundles.map { $0.deletingPathExtension().lastPathComponent }) == requiredRoles
            else {
                throw MarketplaceError.invalidBundle
            }
            for url in bundles {
                guard let bundle = Bundle(url: url),
                    bundle.bundleIdentifier
                        == "com.pulkit.edith.extensions.\(id).\(url.deletingPathExtension().lastPathComponent)",
                    bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == hostABI,
                    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                        == package.version,
                    let executable = bundle.executableURL,
                    FileManager.default.isExecutableFile(atPath: executable.path)
                else { throw MarketplaceError.invalidBundle }
            }
            try verify(carrier, bundles)
            try Task.checkCancellation()
            return .installed(version: package.version, enabled: enabled, active: active)
        } catch is CancellationError { throw CancellationError() } catch {
            return .invalid(
                "Installed package inspection failed: "
                    + String(error.localizedDescription.prefix(3000)))
        }
    }
}
