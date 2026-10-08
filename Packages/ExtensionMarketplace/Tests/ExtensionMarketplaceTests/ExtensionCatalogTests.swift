import CryptoKit
import Foundation
import Testing
@testable import ExtensionMarketplace

func fixturePackage(
    _ id: String = "keepAwake", version: String = "1.0.0", hostABI: String = "host-1",
    dependencies: [String] = [], url: String? = nil
) -> ExtensionPackage {
    ExtensionPackage(
        id: id, version: version, hostABI: hostABI,
        downloadURL: URL(
            string: url
                ?? "https://github.com/example/app/releases/download/extension-\(id)-\(version)/\(id).zip"
        )!,
        sha256: String(repeating: "a", count: 64), downloadBytes: 1024, installedBytes: 2048,
        dependencies: dependencies)
}

@Test func dependenciesInstallBeforeTheRequestedPackage() throws {
    let catalog = ExtensionCatalog(
        revision: 1,
        packages: [
            fixturePackage("shelf", dependencies: ["music"]), fixturePackage("music"),
        ])
    try catalog.validate(repository: "example/app")
    #expect(
        try catalog.installationPlan(
            for: "shelf", hostABI: "host-1", architecture: "arm64", systemVersion: 14
        ).map(\.id) == ["music", "shelf"])
}

@Test func compatibleVersionsAreSelectedAfterAnAppUpdate() throws {
    let catalog = ExtensionCatalog(
        revision: 1,
        packages: [
            fixturePackage(version: "1.9.0"), fixturePackage(version: "1.10.0"),
            fixturePackage(version: "2.0.0", hostABI: "host-2"),
        ])
    #expect(
        try catalog.installationPlan(
            for: "keepAwake", hostABI: "host-1", architecture: "arm64", systemVersion: 14
        ).last?.version == "1.10.0")
    #expect(
        try catalog.installationPlan(
            for: "keepAwake", hostABI: "host-2", architecture: "arm64", systemVersion: 14
        ).last?.version == "2.0.0")
    #expect(throws: MarketplaceError.incompatiblePackage) {
        try catalog.installationPlan(
            for: "keepAwake", hostABI: "host-3", architecture: "arm64", systemVersion: 14)
    }
}

@Test func dependencyCyclesFailWithoutRecursingForever() {
    let catalog = ExtensionCatalog(
        revision: 1,
        packages: [
            fixturePackage("a", dependencies: ["b"]), fixturePackage("b", dependencies: ["a"]),
        ])
    #expect(throws: MarketplaceError.invalidCatalog) {
        try catalog.installationPlan(
            for: "a", hostABI: "host-1", architecture: "arm64", systemVersion: 14)
    }
}

@Test(arguments: ["../outside", ".", "..", "a/b", "a\\b", "", ".hidden", "a%2fb"])
func unsafePackageIdentifiersAreRejected(_ id: String) {
    #expect(!ExtensionPackage.validComponent(id))
}

@Test(arguments: [
    "http://github.com/example/app/releases/download/v1/keepAwake.zip",
    "https://github.com/other/app/releases/download/v1/keepAwake.zip",
    "https://github.com.evil.test/example/app/releases/download/v1/keepAwake.zip",
    "https://github.com/example/app/releases/download/v1/other.zip",
    "https://github.com/example/app/releases/download/v1/keepAwake.zip?token=secret",
])
func foreignOrUnexpectedAssetsAreRejected(_ url: String) {
    #expect(throws: MarketplaceError.invalidCatalog) {
        try fixturePackage(url: url).validate(repository: "example/app")
    }
}

@Test func duplicatePackagesAndMissingDependenciesAreRejected() {
    #expect(throws: MarketplaceError.invalidCatalog) {
        try ExtensionCatalog(revision: 1, packages: [fixturePackage(), fixturePackage()]).validate(
            repository: "example/app")
    }
    #expect(throws: MarketplaceError.invalidCatalog) {
        try ExtensionCatalog(revision: 1, packages: [fixturePackage(dependencies: ["missing"])])
            .validate(repository: "example/app")
    }
}

@Test func catalogSignaturesAndRollbackProtectionAreVerified() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(
        ExtensionCatalog(revision: 2, packages: [fixturePackage()]))
    let signature = try privateKey.signature(for: payload)
    let envelope = SignedExtensionCatalog(payload: payload, signature: signature)
    let publicKey = privateKey.publicKey.rawRepresentation
    #expect(
        try envelope.verified(publicKey: publicKey, repository: "example/app", minimumRevision: 1)
            .revision == 2)
    #expect(throws: MarketplaceError.invalidCatalog) {
        try envelope.verified(publicKey: publicKey, repository: "example/app", minimumRevision: 3)
    }
    #expect(throws: MarketplaceError.invalidSignature) {
        try envelope.verified(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            repository: "example/app")
    }
    #expect(throws: MarketplaceError.invalidSignature) {
        try SignedExtensionCatalog(payload: payload + Data([0]), signature: signature).verified(
            publicKey: publicKey, repository: "example/app")
    }
}
