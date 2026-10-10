import ExtensionMarketplace

extension HostedManagedViewRoute {
    func validate(package: ExtensionPackage) throws {
        try validate(
            extensionID: package.id, version: package.version,
            hostABI: package.hostABI, sourceFingerprint: package.sourceFingerprint)
    }
}
