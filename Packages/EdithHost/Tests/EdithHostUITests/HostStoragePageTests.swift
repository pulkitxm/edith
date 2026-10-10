import AppKit
import CryptoKit
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import Foundation
import SwiftUI
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostStoragePageTests {
    @Test func inventorySeparatesRealPackagesRetainedVersionsUserDataAndSignedDownloads()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let initial = try fixture.inventory()
        #expect(initial.extensions.count == 39)
        #expect(initial.extensions.first { $0.id == "sample" }?.compressedDownloadBytes == nil)
        await fixture.marketplace.loadCachedCatalog()
        let inventory = try fixture.inventory()
        let measurement = try HostStorageAccounting.scan(scopes: inventory.scopes)
        let sample = try #require(inventory.extensions.first { $0.id == "sample" })
        #expect(sample.compressedDownloadBytes == 123)
        #expect(sample.versions.map(\.state) == ["Downloaded, disabled", "Retained version"])
        #expect(sample.versions.allSatisfy { $0.compatible })
        #expect(sample.packageBytes(in: measurement).logical == 12000)
        #expect(measurement.sum(sample.dataScopeIDs).logical == 3250)
        #expect(measurement.sum(sample.versions.flatMap(\.executableScopeIDs)).logical == 6000)
        #expect(measurement.sum(sample.versions.flatMap(\.frameworkScopeIDs)).logical == 4000)
        #expect(
            inventory.categories.reduce(Int64(0)) { $0 + $1.bytes(in: measurement).logical }
                == measurement.total.logical)
        #expect(
            inventory.categories.reduce(Int64(0)) { $0 + $1.bytes(in: measurement).allocated }
                == measurement.total.allocated)
        #expect(measurement.total.complete)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
    }

    @Test func realRemovalDeletesAllPackageVersionsAndRetainsUserData() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let model = HostStoragePageModel()
        await model.refresh(inventory: try fixture.inventory())
        await model.remove(id: "sample", marketplace: fixture.marketplace)
        #expect(model.removalError == nil)
        #expect(model.removalNotice?.contains("user data is retained") == true)
        #expect(try fixture.store.installedPackages().isEmpty)
        for package in fixture.packages {
            #expect(
                !FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
        }
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.data.appendingPathComponent("synthetic-record").path))
        await model.refresh(inventory: try fixture.inventory())
        let measured = try #require(model.measurement)
        let sample = try #require(model.inventory?.extensions.first { $0.id == "sample" })
        #expect(sample.versions.isEmpty)
        #expect(measured.sum(sample.dataScopeIDs).logical == 3250)
        #expect(sample.packageBytes(in: measured).logical == 0)
    }

    @Test func leasedPackagesRemainMeasuredAsPendingRemovalAndRetryUsesTheRealStore() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let lease = try fixture.store.lease(fixture.packages[0])
        defer { lease.close() }
        let model = HostStoragePageModel()
        await model.remove(id: "sample", marketplace: fixture.marketplace)
        #expect(model.removalError == nil)
        #expect(fixture.marketplace.pendingRemovalIDs.contains("sample"))
        #expect(model.removalNotice?.contains("still count") == true)
        await model.refresh(inventory: try fixture.inventory())
        let sample = try #require(model.inventory?.extensions.first { $0.id == "sample" })
        #expect(sample.versions.allSatisfy { $0.state == "Pending removal" })
        #expect(sample.packageBytes(in: try #require(model.measurement)).logical == 12000)
        lease.close()
        await model.remove(id: "sample", marketplace: fixture.marketplace)
        #expect(fixture.marketplace.pendingRemovalIDs.isEmpty)
        #expect(try fixture.store.installedPackages().isEmpty)
    }

    @Test func realDependencyFailureKeepsPackagesAndExposesRemovalFailure() async throws {
        let fixture = try Fixture(dependent: true)
        defer { fixture.clean() }
        let model = HostStoragePageModel()
        await model.remove(id: "sample", marketplace: fixture.marketplace)
        #expect(model.removalError != nil)
        #expect(model.removalNotice == nil)
        #expect(try fixture.store.installedPackages().count == 3)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.store.directory(for: fixture.packages[0]).path))
    }

    @Test func replacementAndCancellationRejectLateScanPublicationWhileRetainingContent()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let inventory = try fixture.inventory()
        let original = try HostStorageAccounting.scan(scopes: inventory.scopes)
        let model = HostStoragePageModel()
        await model.refresh(inventory: inventory)
        let gate = ScanGate()
        let first = Task {
            await model.refresh(inventory: inventory, scan: { _ in await gate.wait() })
        }
        await gate.waitForRequests(1)
        #expect(model.measurement?.total.logical == original.total.logical)
        #expect(model.load.isRefreshing)
        try Data(repeating: 66, count: 18000).write(
            to: fixture.app.appendingPathComponent("Contents/MacOS/Edith"))
        let latest = try HostStorageAccounting.scan(scopes: inventory.scopes)
        let second = Task {
            await model.refresh(inventory: inventory, scan: { _ in await gate.wait() })
        }
        await gate.waitForRequests(2)
        await gate.finish(1, measurement: latest)
        await second.value
        await gate.finish(0, measurement: original)
        await first.value
        #expect(model.measurement?.total.logical == latest.total.logical)
        #expect(await gate.cancelled == 1)
        let third = Task {
            await model.refresh(inventory: inventory, scan: { _ in await gate.wait() })
        }
        await gate.waitForRequests(3)
        model.cancelScan()
        await gate.finish(2, measurement: original)
        await third.value
        #expect(model.measurement?.total.logical == latest.total.logical)
        #expect(!model.load.isRunning)
        #expect(await gate.cancelled == 2)
    }

    @Test func unknownSizesNeverPresentAsKnownSavings() {
        var unknown = HostStorageBytes()
        unknown.complete = false
        #expect(HostStorageSizeLine.value(unknown).hasPrefix("Unknown"))
        unknown.exists = true
        #expect(HostStorageSizeLine.value(unknown).hasPrefix("Partial"))
        #expect(!HostStorageSizeLine.value(unknown).contains("saved"))
    }

    @Test func storageRendersInTheOriginalScaffoldAtCompactRegularZoomAndBothSchemes() async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.marketplace.loadCachedCatalog()
        let model = HostStoragePageModel()
        await model.refresh(inventory: try fixture.inventory())
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        let updater = HostUpdater(startingUpdater: false)
        for (name, width, zoom, scheme) in [
            ("regular-light", 1100.0, 1.0, ColorScheme.light),
            ("regular-dark", 1100.0, 1.0, ColorScheme.dark),
            ("compact-light", 520.0, 1.0, ColorScheme.light),
            ("compact-dark", 520.0, 1.0, ColorScheme.dark),
            ("zoom-light", 700.0, 1.5, ColorScheme.light),
            ("zoom-dark", 1100.0, 1.5, ColorScheme.dark),
        ] {
            UIScale.apply(zoom)
            let host = NSHostingView(
                rootView: HostStoragePage(
                    marketplace: fixture.marketplace, updater: updater, appBundle: fixture.app,
                    appVersion: "1.2.3", model: model
                )
                .environment(\.compactLayout, width < UIScale.pt(720))
                .environment(\.colorScheme, scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded(); window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
            #expect(abs(host.bounds.width - width) < 1)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_STORAGE"] {
                let directory = URL(fileURLWithPath: capture)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent(name + ".png"))
            }
            #expect(!TestWindowHost.isExposedOnDesktop(window))
            #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        }
    }

    private actor ScanGate {
        private var continuations: [Int: CheckedContinuation<HostStorageMeasurement, Never>] = [:]
        private var started = 0
        private(set) var cancelled = 0
        func wait() async -> HostStorageMeasurement {
            let id = started
            started += 1
            let result = await withCheckedContinuation { continuations[id] = $0 }
            if Task.isCancelled { cancelled += 1 }
            return result
        }
        func waitForRequests(_ count: Int) async {
            while started < count { await Task.yield() }
        }
        func finish(_ id: Int, measurement: HostStorageMeasurement) {
            continuations.removeValue(forKey: id)?.resume(returning: measurement)
        }
    }

    @MainActor private struct Fixture {
        let root: URL
        let app: URL
        let data: URL
        let store: ExtensionPackageStore
        let packages: [ExtensionPackage]
        let marketplace: HostMarketplace

        init(dependent: Bool = false) throws {
            root = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent("storage-ui-" + UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.storage-" + UUID().uuidString,
                supportDirectory: root)
            store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
            app = root.appendingPathComponent("Edith.app")
            data = identity.extensionDirectory("sample")
            try Self.file(app.appendingPathComponent("Contents/MacOS/Edith"), count: 7000)
            try Self.file(data.appendingPathComponent("synthetic-record"), count: 3000)
            try Self.file(
                root.appendingPathComponent(
                    "Preferences/" + identity.extensionDefaultsSuite("sample") + ".plist"),
                count: 250)
            try Self.file(
                identity.root.appendingPathComponent("Caches/synthetic-archive.zip"), count: 4000)
            let first = Self.package("sample", "1.0.0")
            let second = Self.package("sample", "2.0.0")
            packages = [first, second]
            for package in packages {
                let carrier = store.directory(for: package).appendingPathComponent(
                    "sample/ExtensionCarrier.app/Contents")
                let worker = carrier.appendingPathComponent(
                    "Extensions/ExtensionWorker.appex/Contents")
                try Self.file(carrier.appendingPathComponent("MacOS/Edith"), count: 1500)
                try Self.file(worker.appendingPathComponent("MacOS/Edith"), count: 1500)
                try Self.file(
                    carrier.appendingPathComponent(
                        "Frameworks/Support.framework/Versions/A/Support"), count: 2000)
                try Self.file(
                    worker.appendingPathComponent(
                        "Resources/Payload/sample/app.bundle/Contents/MacOS/Runtime"), count: 1000)
            }
            var installed = packages
            if dependent {
                let dependency = Self.package("tool1", "1.0.0", dependencies: ["sample"])
                try Self.file(
                    store.directory(for: dependency).appendingPathComponent("synthetic-runtime"),
                    count: 1)
                installed.append(dependency)
            }
            try store.commit(installed)
            let key = Curve25519.Signing.PrivateKey()
            let cache = identity.root.appendingPathComponent("catalog.json")
            let payload = try JSONEncoder().encode(
                ExtensionCatalog(revision: 1, packages: [second]))
            try JSONEncoder().encode(
                SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload))
            ).write(to: cache)
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let sessions = HostExtensionSessions(defaults: defaults) { _ in
                throw HostWorkerError.rejected
            }
            marketplace = try HostMarketplace(
                identity: identity,
                entries: [
                    HostExtension(
                        id: "sample", title: "Sample extension", symbolName: "square",
                        category: "Tools")
                ]
                    + (1..<39).map {
                        HostExtension(
                            id: "tool\($0)", title: "Sample tool \($0)", symbolName: "square",
                            category: "Tools")
                    },
                store: store,
                catalogClient: ExtensionCatalogClient(
                    url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                    publicKey: key.publicKey.rawRepresentation,
                    repository: MarketplaceConfiguration.repository, cache: cache,
                    fetch: { _ in throw MarketplaceError.downloadFailed }),
                installer: ExtensionPackageInstaller(
                    store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                    verify: { _ in }), sessions: sessions)
        }

        func inventory() throws -> HostStorageInventory {
            try HostStorageInventory(
                marketplace: marketplace, appBundle: app, appVersion: "1.2.3",
                preferencesDirectory: root.appendingPathComponent("Preferences"))
        }

        private static func package(_ id: String, _ version: String, dependencies: [String] = [])
            -> ExtensionPackage
        {
            ExtensionPackage(
                id: id, version: version, hostABI: HostContract.compatibility,
                downloadURL: URL(
                    string:
                        "https://github.com/pulkitxm/edith/releases/download/synthetic/\(id).zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 123, installedBytes: 6000,
                dependencies: dependencies)
        }

        private static func file(_ url: URL, count: Int) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: count).write(to: url)
        }

        func clean() {
            UserDefaults(suiteName: marketplace.identity.defaultsSuite)?.removePersistentDomain(
                forName: marketplace.identity.defaultsSuite)
            for entry in marketplace.entries {
                let suite = marketplace.identity.extensionDefaultsSuite(entry.id)
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
