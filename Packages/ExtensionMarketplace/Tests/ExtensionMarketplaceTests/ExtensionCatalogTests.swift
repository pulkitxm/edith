import CryptoKit
import Foundation
import Testing
@testable import ExtensionMarketplace

func fixturePackage(
    _ id: String = "keepAwake", version: String = "1.0.0", hostABI: String = "host-1",
    dependencies: [String] = [], url: String? = nil, minimumHostBuild: Int? = nil
) -> ExtensionPackage {
    ExtensionPackage(
        id: id, version: version, hostABI: hostABI, minimumHostBuild: minimumHostBuild,
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
            for: "shelf", hostABI: "host-1", architecture: "arm64", systemVersion: .init(major: 14)
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
            for: "keepAwake", hostABI: "host-1", architecture: "arm64",
            systemVersion: .init(major: 14)
        ).last?.version == "1.10.0")
    #expect(
        try catalog.installationPlan(
            for: "keepAwake", hostABI: "host-2", architecture: "arm64",
            systemVersion: .init(major: 14)
        ).last?.version == "2.0.0")
    #expect(throws: MarketplaceError.incompatiblePackage) {
        try catalog.installationPlan(
            for: "keepAwake", hostABI: "host-3", architecture: "arm64",
            systemVersion: .init(major: 14))
    }
}

@Test func buildsNeedingANewerHostAreSkippedForTheLastCompatibleVersion() throws {
    let payload = Data(
        """
        {"schemaVersion":1,"revision":7,"packages":[
        {"id":"usage","version":"1.0.2","hostABI":"edith-host-11","architecture":"arm64",
        "minimumSystemVersion":"14.0.0",
        "downloadURL":"https://github.com/example/app/releases/download/usage-1.0.2/usage.zip",
        "sha256":"\(String(repeating: "a", count: 64))","downloadBytes":1024,
        "installedBytes":2048,"dependencies":[]},
        {"id":"usage","version":"1.0.3","hostABI":"edith-host-11","architecture":"arm64",
        "minimumSystemVersion":"14.0.0","minimumHostBuild":396,
        "downloadURL":"https://github.com/example/app/releases/download/usage-1.0.3/usage.zip",
        "sha256":"\(String(repeating: "b", count: 64))","downloadBytes":1024,
        "installedBytes":2048,"dependencies":[]}]}
        """.utf8)
    let catalog = try JSONDecoder().decode(ExtensionCatalog.self, from: payload)
    try catalog.validate(repository: "example/app")
    #expect(catalog.packages.map(\.minimumHostBuild) == [nil, 396])
    func selected(hostBuild: Int) throws -> String? {
        try catalog.installationPlan(
            for: "usage", hostABI: "edith-host-11", architecture: "arm64",
            systemVersion: .init(major: 14), hostBuild: hostBuild
        ).last?.version
    }
    #expect(try selected(hostBuild: 395) == "1.0.2")
    #expect(try selected(hostBuild: 396) == "1.0.3")
    #expect(
        !catalog.packages[1].isCompatible(
            hostABI: "edith-host-11", architecture: "arm64", systemVersion: .init(major: 14),
            hostBuild: 395))
    #expect(throws: MarketplaceError.incompatiblePackage) {
        try catalog.packages[1].admitting(
            hostABI: "edith-host-11", architecture: "arm64", systemVersion: .init(major: 14),
            hostBuild: 395
        ) {}
    }
}

@Test func packagesWithoutAHostBuildRequirementKeepTheirEncodedShape() throws {
    let package = fixturePackage()
    let encoded = try JSONEncoder().encode(package)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("minimumHostBuild"))
    #expect(try JSONDecoder().decode(ExtensionPackage.self, from: encoded) == package)
    #expect(
        package.isCompatible(
            hostABI: "host-1", architecture: "arm64", systemVersion: .init(major: 14),
            hostBuild: 0))
}

@Test(arguments: [0, -1])
func invalidHostBuildRequirementsAreRejected(_ build: Int) {
    #expect(throws: MarketplaceError.invalidCatalog) {
        try fixturePackage(url: nil, minimumHostBuild: build).validate(repository: "example/app")
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
            for: "a", hostABI: "host-1", architecture: "arm64", systemVersion: .init(major: 14))
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

@Test func hostVersionsAcceptPackagesFromTheMinimumUpToTheHost() {
    #expect(ExtensionHostABI.accepts("edith-host-8", host: "edith-host-9", minimum: "edith-host-8"))
    #expect(ExtensionHostABI.accepts("edith-host-9", host: "edith-host-9", minimum: "edith-host-8"))
    #expect(
        !ExtensionHostABI.accepts("edith-host-7", host: "edith-host-9", minimum: "edith-host-8"))
    #expect(
        !ExtensionHostABI.accepts("edith-host-10", host: "edith-host-9", minimum: "edith-host-8"))
    #expect(ExtensionHostABI.accepts("host-1", host: "host-1"))
    #expect(!ExtensionHostABI.accepts("host-1", host: "host-2"))
    #expect(
        ExtensionHostABI.accepted(host: "edith-host-10", minimum: "edith-host-8") == [
            "edith-host-8", "edith-host-9", "edith-host-10",
        ])
}

@Test func theNewestPackageInsideTheHostRangeIsInstalled() throws {
    let host =
        "edith-host-"
        + String(
            Int(MarketplaceConfiguration.workerHostABI.dropFirst("edith-host-".count))! + 1)
    let catalog = ExtensionCatalog(
        revision: 1,
        packages: [
            fixturePackage("shelf", version: "2.0.0", hostABI: host, dependencies: ["music"]),
            fixturePackage(
                "music", version: "1.0.0", hostABI: MarketplaceConfiguration.minimumWorkerHostABI),
            fixturePackage("music", version: "0.9.0", hostABI: "edith-host-1"),
        ])
    #expect(
        try catalog.installationPlan(
            for: "shelf", hostABI: host, architecture: "arm64", systemVersion: .init(major: 14)
        ).map { "\($0.id)@\($0.version)" } == ["music@1.0.0", "shelf@2.0.0"])
    #expect(throws: MarketplaceError.self) {
        try catalog.installationPlan(
            for: "shelf", hostABI: MarketplaceConfiguration.workerHostABI, architecture: "arm64",
            systemVersion: .init(major: 14))
    }
}
