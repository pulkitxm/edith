import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Testing
@testable import EdithHostCore

@Suite struct HostProductionPersistenceTests {
    @Test func productionIdentityKeepsOriginalPreferencesButIsolatesPackageState() throws {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        #expect(identity.applicationDefaultsSuite == "com.pulkit.edith.shared")
        #expect(identity.defaultsSuite == "com.pulkit.edith.host")
        for id in try HostIndex.bundled().map(\.id) {
            #expect(identity.extensionDefaultsSuite(id) == identity.applicationDefaultsSuite)
        }
        let isolated = try HostIdentity(
            identifier: "com.pulkit.edith.tests.synthetic",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        #expect(
            isolated.extensionDefaultsSuite("usage")
                == "com.pulkit.edith.tests.synthetic.extensions.usage")
        #expect(
            isolated.effectiveExtensionDirectory("usage") == isolated.extensionDirectory("usage"))
    }

    @Test func actualProductionPathsDiagnosticsAndStorageTargetsAgree() throws {
        let support = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent(
                UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let identity = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: support)
        let usage = identity.root.appendingPathComponent("data/usage.json")
        try FileManager.default.createDirectory(
            at: usage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("synthetic-history".utf8)
        try bytes.write(to: usage)
        #expect(
            try Data(
                contentsOf: identity.effectiveExtensionDirectory("usage").appendingPathComponent(
                    "data/usage.json")) == bytes)
        let suite = "host-production-paths-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = HostAppPathsCLI.entries(identity: identity, defaults: defaults)
        #expect(diagnostics.first { $0.id == "data" }?.url == usage.deletingLastPathComponent())
        #expect(
            try HostAppPathsCLI.prepareOpen("data", identity: identity, defaults: defaults).url
                == usage.deletingLastPathComponent())
        #expect(
            HostStorageTarget.defaults(identity: identity, defaults: defaults).first {
                $0.id == "usage"
            }?.url
                == usage.deletingLastPathComponent())
        #expect(
            identity.persistentExtensionLocations("herdr")[0]
                == identity.root.appendingPathComponent("herdr"))
        #expect(
            identity.effectiveExtensionDirectory("machines")
                == identity.root.appendingPathComponent("machines", isDirectory: true))
    }

    @Test func storedCustomMusicDirectoryIsTheActualDiagnosticAndStorageTarget() throws {
        let suite = "host-production-music-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let library = home.appendingPathComponent("Music/Selected")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defaults.set(library.path, forKey: AppStorageKeys.Music.folderPath)
        let identity = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: root)
        #expect(
            HostAppPathsCLI.entries(identity: identity, defaults: defaults, homeDirectory: home)
                .first { $0.id == "music" }?.url.path == library.resolvingSymlinksInPath().path)
        #expect(
            try HostAppPathsCLI.prepareOpen(
                "music", identity: identity, defaults: defaults,
                homeDirectory: home
            ).url.path == library.resolvingSymlinksInPath().path)
        #expect(
            HostStorageTarget.defaults(identity: identity, defaults: defaults, homeDirectory: home)
                .first { $0.id == "music" }?.url.path == library.resolvingSymlinksInPath().path)
    }

    @Test func packageReplacementAndRemovalCannotDeleteOriginalOrNewOwnerData() throws {
        let support = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent(
                UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let identity = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: support)
        let old = identity.root.appendingPathComponent("data/usage.json")
        let new = identity.extensionDirectory("usage").appendingPathComponent("data/usage.json")
        for file in [old, new] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file == old ? "original".utf8 : "new".utf8).write(to: file)
        }
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let packages = ["1.0.0", "2.0.0"].map { version in
            ExtensionPackage(
                id: "usage", version: version, hostABI: HostContract.compatibility,
                downloadURL: URL(string: "https://example.invalid/usage.zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        }
        for package in packages {
            try FileManager.default.createDirectory(
                at: store.directory(for: package), withIntermediateDirectories: true)
        }
        try store.commit(packages)
        try store.select(packages[1])
        #expect(try store.remove(id: "usage"))
        #expect(try Data(contentsOf: old) == Data("original".utf8))
        #expect(try Data(contentsOf: new) == Data("new".utf8))
        #expect(try store.installedPackages().isEmpty)
    }

    @Test func preservedScopesAndSharedPreferencesAreAccountedExactlyOnce() throws {
        let support = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent(
                UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let identity = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: support)
        let file = identity.root.appendingPathComponent("data/usage.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 71).write(to: file)
        let prefs = support.appendingPathComponent("shared.plist")
        try Data(repeating: 2, count: 29).write(to: prefs)
        let measurement = try HostStorageAccounting.scan(scopes: [
            .init(id: "host", root: identity.root),
            .init(id: "usage", root: identity.persistentExtensionLocations("usage")[0]),
            .init(id: "shared", root: prefs),
        ])
        #expect(measurement.issues.isEmpty)
        #expect(measurement.bytes["usage"]?.logical == 71)
        #expect(measurement.bytes["shared"]?.logical == 29)
        #expect(measurement.total.logical == 100)
    }
}
