import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing
@testable import HostLifecycleHarness

@Suite struct CalendarLifecycleFixtureTests {
    @Test func selectedVersionMarkerUpdatesWithoutChangingPrivateIdentity() throws {
        try fixture { root, identity in
            let helper = try CalendarLifecycleFixture(directory: root, identity: identity)
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            for version in ["1.0.0", "1.1.0", "1.0.0"] {
                let selected = package(version)
                let path = store.directory(for: selected).appendingPathComponent("calendar")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try helper.prepare(package: selected, store: store)
                let marker = helper.home.appendingPathComponent("calendar-fixture.json")
                let value = try #require(
                    try JSONSerialization.jsonObject(with: Data(contentsOf: marker))
                        as? [String: Any])
                #expect(value["packageDirectory"] as? String == path.path)
                #expect(
                    value["dataDirectory"] as? String
                        == identity.extensionDirectory("calendar").path)
                #expect(value["hostIdentifier"] as? String == identity.identifier)
                #expect(
                    try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions]
                        as? Int == 0o600)
                #expect(
                    try FileManager.default.attributesOfItem(atPath: helper.home.path)[
                        .posixPermissions] as? Int == 0o700)
            }
        }
    }

    @Test(arguments: ["named", "wrong-support", "public-home", "aliased-home"])
    func invalidFixtureOwnershipIsRejected(mode: String) throws {
        try fixture { root, identity in
            let selectedIdentity = try HostIdentity(
                identifier: mode == "named"
                    ? "com.pulkit.edith.tests.remote-owned-20261010" : identity.identifier,
                supportDirectory: mode == "wrong-support"
                    ? root : root.appendingPathComponent("support"))
            let home = root.appendingPathComponent("synthetic-data")
            if mode == "public-home" {
                try FileManager.default.createDirectory(
                    at: home, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755])
            } else if mode == "aliased-home" {
                try FileManager.default.createSymbolicLink(at: home, withDestinationURL: root)
            }
            #expect(throws: (any Error).self) {
                try CalendarLifecycleFixture(directory: root, identity: selectedIdentity)
            }
        }
    }

    @Test(arguments: [
        "foreign-marker", "public-marker", "oversize-marker", "aliased-package", "foreign-store",
    ])
    func markerAndSelectedPackageMustRemainOwned(mode: String) throws {
        try fixture { root, identity in
            let helper = try CalendarLifecycleFixture(directory: root, identity: identity)
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            let selected = package("1.0.0")
            let path = store.directory(for: selected).appendingPathComponent("calendar")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try helper.prepare(package: selected, store: store)
            let marker = helper.home.appendingPathComponent("calendar-fixture.json")
            if mode == "foreign-marker" { try Data("{}".utf8).write(to: marker) }
            if mode == "oversize-marker" {
                try Data(repeating: 32, count: 16_385).write(to: marker)
            }
            if mode == "public-marker" {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: marker.path)
            }
            if mode == "aliased-package" {
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root)
            }
            let testedStore = mode == "foreign-store" ? ExtensionPackageStore(root: root) : store
            #expect(throws: (any Error).self) {
                try helper.prepare(package: selected, store: testedStore)
            }
        }
    }

    private func fixture(_ run: (URL, HostIdentity) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: canonical.appendingPathComponent("Host.app"), withIntermediateDirectories: false)
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.remote-" + UUID().uuidString,
            supportDirectory: canonical.appendingPathComponent("support"))
        try run(canonical, identity)
    }

    private func package(_ version: String) -> ExtensionPackage {
        .init(
            id: "calendar", version: version, hostABI: "edith-host-2",
            downloadURL: URL(string: "https://example.invalid/calendar.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
    }
}
