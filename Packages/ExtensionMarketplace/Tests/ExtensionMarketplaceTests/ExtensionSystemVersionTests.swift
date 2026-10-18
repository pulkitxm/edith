import Foundation
import Testing
@testable import ExtensionMarketplace

@Test(arguments: ["14.3.0", "14.4.0", "14.5.0", "15.0.0"])
func minorSystemAdmissionControlsAvailabilityAndWorkerCreation(_ version: String) throws {
    let system = try #require(ExtensionSystemVersion(version))
    let package = ExtensionPackage(
        id: "audioMixer", version: "1.0.0", hostABI: "host-1",
        minimumSystemVersion: .init(major: 14, minor: 4),
        downloadURL: URL(
            string: "https://github.com/example/app/releases/download/synthetic/audioMixer.zip")!,
        sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
    let catalog = ExtensionCatalog(revision: 1, packages: [package])
    try catalog.validate(repository: "example/app")
    let available = catalog.packages.filter {
        $0.isCompatible(hostABI: "host-1", architecture: "arm64", systemVersion: system)
    }
    var workerCreations = 0
    let createWorker = { workerCreations += 1 }
    if version == "14.3.0" {
        #expect(available.isEmpty)
        #expect(throws: MarketplaceError.incompatiblePackage) {
            try catalog.installationPlan(
                for: package.id, hostABI: "host-1", architecture: "arm64", systemVersion: system)
        }
        #expect(throws: MarketplaceError.incompatiblePackage) {
            try package.admitting(
                hostABI: "host-1", architecture: "arm64", systemVersion: system,
                operation: createWorker)
        }
        #expect(workerCreations == 0)
    } else {
        #expect(available == [package])
        let plan = try catalog.installationPlan(
            for: package.id, hostABI: "host-1", architecture: "arm64", systemVersion: system)
        #expect(plan == [package])
        try plan[0].admitting(
            hostABI: "host-1", architecture: "arm64", systemVersion: system,
            operation: createWorker)
        #expect(workerCreations == 1)
    }
    for (abi, architecture) in [("host-2", "arm64"), ("host-1", "x86_64")] {
        #expect(throws: MarketplaceError.incompatiblePackage) {
            try package.admitting(
                hostABI: abi, architecture: architecture, systemVersion: system,
                operation: createWorker)
        }
    }
    #expect(workerCreations == (version == "14.3.0" ? 0 : 1))
}

@Test(arguments: [
    "14", "14.4", "14.4.0.0", "14..0", "14.04.0", "014.4.0", "14.4.-1", "14.4.+1",
    " 14.4.0", "14.4.0\n", "14.4.0-beta", "14.4.\u{0660}", "14.4.2147483648", "",
])
func malformedSystemVersionsAreRejected(_ value: String) throws {
    #expect(ExtensionSystemVersion(value) == nil)
    let encoded = try JSONEncoder().encode(value)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ExtensionSystemVersion.self, from: encoded)
    }
}

@Test func systemVersionEncodingAndNumericOrderingAreCanonical() throws {
    let version = ExtensionSystemVersion(major: 14, minor: 4, patch: 1)
    #expect(try JSONEncoder().encode(version) == Data("\"14.4.1\"".utf8))
    #expect(
        try JSONDecoder().decode(ExtensionSystemVersion.self, from: Data("\"14.4.1\"".utf8))
            == version)
    for data in [Data("14".utf8), Data("14.4".utf8), Data("null".utf8), Data("{}".utf8)] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ExtensionSystemVersion.self, from: data)
        }
    }
    #expect(ExtensionSystemVersion(major: 14, minor: 4) < version)
    #expect(version < ExtensionSystemVersion(major: 14, minor: 10))
    #expect(ExtensionSystemVersion(major: 14, minor: 99) < ExtensionSystemVersion(major: 15))
    #expect(
        ExtensionSystemVersion(.init(majorVersion: 14, minorVersion: 4, patchVersion: 1)) == version
    )
}

@Test func sealedPayloadRequiresTheCatalogMinimumSystemVersion() throws {
    let package = ExtensionPackage(
        id: "audioMixer", version: "1.0.0", hostABI: "host-1",
        minimumSystemVersion: .init(major: 14, minor: 4),
        downloadURL: URL(
            string: "https://github.com/example/app/releases/download/synthetic/audioMixer.zip")!,
        sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
    let manifest = ExtensionPayloadManifest(package: package)
    let data = try JSONEncoder().encode(manifest)
    #expect(try JSONDecoder().decode(ExtensionPayloadManifest.self, from: data) == manifest)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["minimumSystemVersion"] as? String == "14.4.0")
    object["minimumSystemVersion"] = "14.0.0"
    #expect(
        try JSONDecoder().decode(
            ExtensionPayloadManifest.self, from: JSONSerialization.data(withJSONObject: object))
            != manifest)
    for value in [14, "14.4", "14.04.0"] as [Any] {
        object["minimumSystemVersion"] = value
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ExtensionPayloadManifest.self, from: malformed)
        }
    }
    object.removeValue(forKey: "minimumSystemVersion")
    let missing = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ExtensionPayloadManifest.self, from: missing)
    }
}
