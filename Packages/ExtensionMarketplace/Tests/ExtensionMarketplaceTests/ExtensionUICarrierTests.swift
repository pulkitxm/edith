import Foundation
import Testing
import ZIPFoundation
@testable import ExtensionMarketplace

private struct UICarrierFixture {
    let root: URL
    let package: ExtensionPackage
    let carrier: URL
    let worker: URL
    let host = "com.pulkit.edith.tests.ui"

    init(id: String = "calendar") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "extension-ui-test-\(UUID().uuidString)")
        package = fixturePackage(id)
        carrier = root.appendingPathComponent("ExtensionCarrier.app")
        worker = carrier.appendingPathComponent("Contents/Extensions/ExtensionWorker.appex")
        let shared: [String: Any] = [
            "CFBundleExecutable": "Edith",
            "CFBundleShortVersionString": package.version,
            "CFBundleVersion": package.version,
            "EdithHostIdentifier": host,
            "EdithExtensionID": package.id,
            "EdithExtensionVersion": package.version,
            "EdithHostABI": package.hostABI,
            "EdithHostExecutablePath": "/tmp/fixture/Host.app/Contents/MacOS/Edith",
            "EdithHostCodeRequirement": "identifier \"com.pulkit.edith.tests.ui\"",
            "EdithExecutableProvenance": String(repeating: "a", count: 64),
            "EdithPayloadRelativePath": "Contents/Resources/Payload",
        ]
        var applicationInfo = shared
        applicationInfo["CFBundleIdentifier"] = "\(host).extension.\(id)"
        applicationInfo["CFBundlePackageType"] = "APPL"
        applicationInfo["LSUIElement"] = true
        var workerInfo = shared
        workerInfo["CFBundleIdentifier"] = "\(host).extension.\(id).worker"
        workerInfo["CFBundlePackageType"] = "XPC!"
        workerInfo["EXAppExtensionAttributes"] = [
            "EXExtensionPointIdentifier": "\(host).ExtensionUI"
        ]
        for (bundle, info) in [(carrier, applicationInfo), (worker, workerInfo)] {
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("Contents/MacOS"),
                withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            let executable = bundle.appendingPathComponent("Contents/MacOS/Edith")
            try Data("synthetic runtime".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let selectedPayload = worker.appendingPathComponent("Contents/Resources/Payload/\(id)")
        try FileManager.default.createDirectory(
            at: selectedPayload, withIntermediateDirectories: true)
        try JSONEncoder().encode(ExtensionPayloadManifest(package: package))
            .write(to: selectedPayload.appendingPathComponent("package.json"))
    }

    func mutate(_ bundle: URL, key: String, value: Any) throws {
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        var dictionary = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
                as? [String: Any])
        dictionary[key] = value
        try PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .binary, options: 0
        )
        .write(to: info)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }

    func sign(workerEntitlements: [String: Any], carrierEntitlements: [String: Any] = [:]) throws {
        for bundle in [worker, carrier] {
            let executable = bundle.appendingPathComponent("Contents/MacOS/Edith")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        }
        for (bundle, entitlements) in [
            (worker, workerEntitlements), (carrier, carrierEntitlements),
        ] {
            let plist = root.appendingPathComponent("entitlements.plist")
            try PropertyListSerialization.data(
                fromPropertyList: entitlements, format: .xml, options: 0
            )
            .write(to: plist)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = [
                "--force", "--sign", "-", "--entitlements", plist.path, bundle.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}

@Test(arguments: ["calendar", "music", "notchShelf", "camera", "micMute"])
func signedWorkerRequiresExactlyItsOwnedCapabilities(id: String) throws {
    let fixture = try UICarrierFixture(id: id)
    defer { fixture.clean() }
    let selected = try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    var expected: [String: Any] = ["com.apple.security.app-sandbox": true]
    let network = ["music", "notchShelf"].contains(id)
    if network { expected["com.apple.security.network.client"] = true }
    try fixture.sign(workerEntitlements: expected)
    try selected.verifyDevelopment()
    var wrongNetwork = expected
    if network {
        wrongNetwork.removeValue(forKey: "com.apple.security.network.client")
    } else {
        wrongNetwork["com.apple.security.network.client"] = true
    }
    try fixture.sign(workerEntitlements: wrongNetwork)
    #expect(throws: MarketplaceError.invalidSignature) { try selected.verifyDevelopment() }
    for key in [
        "com.apple.security.device.camera", "com.apple.security.device.audio-input",
        "com.apple.security.network.server", "com.apple.security.files.user-selected.read-write",
    ] {
        var extra = expected
        extra[key] = true
        try fixture.sign(workerEntitlements: extra)
        #expect(throws: MarketplaceError.invalidSignature) { try selected.verifyDevelopment() }
    }
    for key in expected.keys {
        var missing = expected
        missing.removeValue(forKey: key)
        try fixture.sign(workerEntitlements: missing)
        #expect(throws: MarketplaceError.invalidSignature) { try selected.verifyDevelopment() }
        for invalid in [false as Any, 1 as Any, "true" as Any] {
            var wrongType = expected
            wrongType[key] = invalid
            try fixture.sign(workerEntitlements: wrongType)
            #expect(throws: MarketplaceError.invalidSignature) { try selected.verifyDevelopment() }
        }
    }
    try fixture.sign(
        workerEntitlements: expected,
        carrierEntitlements: ["com.apple.security.network.client": true])
    #expect(throws: MarketplaceError.invalidSignature) { try selected.verifyDevelopment() }
}

@Test func selectedCarrierRequiresMatchingHostPackageAndSceneIdentity() throws {
    let fixture = try UICarrierFixture()
    defer { fixture.clean() }
    let selected = try ExtensionUICarrier(
        payload: fixture.root, package: fixture.package, expectedHostIdentifier: fixture.host)
    #expect(selected.workerIdentifier == "\(fixture.host).extension.calendar.worker")
    #expect(selected.extensionPointIdentifier == "\(fixture.host).ExtensionUI")
    #expect(throws: MarketplaceError.invalidArchive) {
        try ExtensionUICarrier(
            payload: fixture.root, package: fixture.package,
            expectedHostIdentifier: "com.pulkit.edith.tests.other")
    }
    try fixture.mutate(fixture.worker, key: "EdithExtensionVersion", value: "2.0.0")
    #expect(throws: MarketplaceError.invalidArchive) {
        try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    }
}

@Test(arguments: [
    "EdithHostABI", "EdithExtensionID", "CFBundleIdentifier", "EdithPayloadRelativePath",
])
func changedWorkerSealedMetadataIsRejected(key: String) throws {
    let fixture = try UICarrierFixture()
    defer { fixture.clean() }
    try fixture.mutate(fixture.worker, key: key, value: "forged")
    #expect(throws: MarketplaceError.invalidArchive) {
        try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    }
}

@Test func malformedRequirementsAndUnexpectedExtensionPointsAreRejected() throws {
    let fixture = try UICarrierFixture()
    defer { fixture.clean() }
    try fixture.mutate(
        fixture.worker, key: "EXAppExtensionAttributes",
        value: ["EXExtensionPointIdentifier": "com.example.Other"])
    #expect(throws: MarketplaceError.invalidArchive) {
        try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    }
    try fixture.mutate(fixture.carrier, key: "EdithHostCodeRequirement", value: "not a requirement")
    #expect(throws: MarketplaceError.invalidArchive) {
        try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    }
}

@Test func unsignedCarrierCannotPassDevelopmentOrPublisherVerification() throws {
    let fixture = try UICarrierFixture()
    defer { fixture.clean() }
    let selected = try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    #expect(throws: MarketplaceError.invalidSignature) { try selected.verifyDevelopment() }
    #expect(throws: MarketplaceError.invalidSignature) {
        try selected.verify(teamIdentifier: "FIXTURE123")
    }
}

@Test func UIExecutableAndFrameworkSymlinksAreRejected() throws {
    let fixture = try UICarrierFixture()
    defer { fixture.clean() }
    let framework = fixture.carrier.appendingPathComponent("Contents/Frameworks")
    try FileManager.default.createSymbolicLink(
        at: framework, withDestinationURL: fixture.root)
    #expect(throws: MarketplaceError.invalidArchive) {
        try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    }
}

@Test func productionCarrierCannotSealABuildMachinePath() throws {
    let fixture = try UICarrierFixture()
    defer { fixture.clean() }
    try fixture.mutate(fixture.carrier, key: "EdithHostIdentifier", value: "com.pulkit.edith")
    #expect(throws: MarketplaceError.invalidArchive) {
        try ExtensionUICarrier(payload: fixture.root, package: fixture.package)
    }
}

@Test(arguments: [false, true])
func archiveValidatesCarrierMetadataBeforeItCanBeCommitted(forged: Bool) throws {
    let fixture = try UICarrierFixture()
    defer { fixture.clean() }
    try FileManager.default.createDirectory(
        at: fixture.worker.appendingPathComponent(
            "Contents/Resources/Payload/calendar/app.bundle/Contents/MacOS"),
        withIntermediateDirectories: true)
    try Data("synthetic feature".utf8).write(
        to: fixture.worker.appendingPathComponent(
            "Contents/Resources/Payload/calendar/app.bundle/Contents/MacOS/Runtime"))
    try JSONEncoder().encode(ExtensionPayloadManifest(package: fixture.package))
        .write(to: fixture.root.appendingPathComponent("package.json"))
    if forged { try fixture.mutate(fixture.worker, key: "EdithExtensionID", value: "music") }
    let archiveURL = fixture.root.appendingPathComponent("test.zip")
    let zip = try Archive(url: archiveURL, accessMode: .create)
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: fixture.root, includingPropertiesForKeys: [.isRegularFileKey]))
    var expandedBytes = 0
    for case let url as URL in enumerator where url.lastPathComponent != "test.zip" {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            continue
        }
        let bytes = try Data(contentsOf: url)
        let path =
            "\(fixture.package.id)/"
            + String(
                url.standardizedFileURL.path.dropFirst(
                    fixture.root.standardizedFileURL.path.count + 1))
        try zip.addEntry(with: path, fileURL: url)
        expandedBytes += bytes.count
    }
    let package = ExtensionPackage(
        id: fixture.package.id, version: fixture.package.version, hostABI: fixture.package.hostABI,
        downloadURL: fixture.package.downloadURL, sha256: fixture.package.sha256,
        downloadBytes: fixture.package.downloadBytes, installedBytes: Int64(expandedBytes))
    if forged {
        #expect(throws: MarketplaceError.invalidArchive) {
            try ExtensionArchive.extract(
                archiveURL, package: package, to: fixture.root.appendingPathComponent("extracted"))
        }
    } else {
        try ExtensionArchive.extract(
            archiveURL, package: package, to: fixture.root.appendingPathComponent("extracted"))
        let installed = fixture.root.appendingPathComponent("extracted/calendar")
        let carrier = try ExtensionUICarrier(payload: installed, package: package)
        #expect(
            FileManager.default.fileExists(
                atPath: carrier.payloadDirectory.appendingPathComponent(
                    "app.bundle/Contents/MacOS/Runtime"
                ).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: installed.appendingPathComponent("app.bundle").path))
    }
}
