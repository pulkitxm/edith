import AppKit
import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import HostAccessibilityFixtureSupport
import HostWorkerFixtureSupport
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostNavigationPlacementTests {
    static let utilities = ["appMaintenance", "homebrew", "cleaner", "blitztree", "system"]

    private static func manifestDirectories() throws -> Set<String> {
        let extensions = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions")
        let names = try FileManager.default.contentsOfDirectory(atPath: extensions.path)
        return Set(
            names.filter {
                FileManager.default.fileExists(
                    atPath: extensions.appendingPathComponent($0 + "/package.json").path)
            })
    }

    @Test func everyBundledExtensionAppearsOnceUnderItsOwnCategoryWithItsOwnName() throws {
        let entries = try HostIndex.bundled()
        #expect(Set(entries.map(\.id)) == (try Self.manifestDirectories()))
        #expect(entries.count == 41)
        let pages = HostNavigationCatalog.pages(entries)
        let active = Set(entries.map(\.id))
        let defaults = try #require(UserDefaults(suiteName: "placement-" + UUID().uuidString))
        let visible = pages.filter {
            HostNavigationCatalog.visible($0, active: active, defaults: defaults)
        }
        let suites = Dictionary(
            uniqueKeysWithValues: HostMarketplaceCatalog.suites.map { ($0.id, $0) })
        for page in visible where page.landing {
            #expect(page.id == page.suite, "\(page.id)")
            #expect(page.title == suites[page.id]?.title, "\(page.id)")
            #expect(page.sections.isEmpty, "\(page.id)")
        }
        for entry in entries {
            #expect(HostExtensionIcon.resolve(entry) == entry.icon, "\(entry.id)")
            #expect(
                EdithIcon(rawValue: entry.id).map { $0 == entry.icon } ?? true,
                "\(entry.id) has a dedicated icon its manifest does not use")
            let owned = visible.filter { $0.extensionID == entry.id }
            if entry.page == nil {
                #expect(owned.isEmpty, "\(entry.id)")
                continue
            }
            #expect(owned.count == 1, "\(entry.id)")
            let page = try #require(owned.first)
            let parent = try #require(visible.first { $0.id == page.parentID }, "\(entry.id)")
            #expect(page.id == entry.id)
            #expect(page.title == entry.title, "\(entry.id)")
            #expect(page.icon == entry.icon, "\(entry.id)")
            #expect(page.icon == HostExtensionIcon.resolve(entry), "\(entry.id)")
            #expect(page.suite == entry.category, "\(entry.id)")
            #expect(parent.landing && parent.suite == entry.category, "\(entry.id)")
            #expect(parent.title == suites[entry.category]?.title, "\(entry.id)")
        }
        let titles = visible.map(\.title)
        #expect(!titles.contains("Maintenance"))
        #expect(!titles.contains("Packages"))
        #expect(Set(visible.map(\.id)).count == visible.count)
        #expect(
            Set(visible.map(\.title)).count == visible.count,
            "\(Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys)")
    }

    @Test func eachSidebarGroupListsItsLandingPageExtensionsInTheSameOrder() throws {
        let entries = try HostIndex.bundled()
        let pages = HostNavigationCatalog.pages(entries)
        for landing in pages.filter(\.landing) {
            let suite = try #require(landing.suite)
            let listed = HostSuiteLandingGroups.groups(
                suite: suite, entries: entries.filter { $0.category == suite }
            ).flatMap(\.entries)
            let children = pages.filter { $0.parentID == landing.id }
            #expect(
                children.map(\.id) == listed.filter { $0.page != nil }.map(\.id), "\(suite)")
            #expect(
                Set(listed.map(\.id)).isSuperset(of: children.compactMap(\.extensionID)),
                "\(suite)")
        }
        #expect(
            pages.filter { $0.parentID == "utilities" }.map(\.title) == [
                "App Updates", "Homebrew", "Cleaner", "Disk Map", "Running Apps", "Calendar",
            ])
        #expect(HostNavigationCatalog.route(extensionID: "homebrew") == "homebrew")
        #expect(HostNavigationCatalog.route(extensionID: "appMaintenance") == "appMaintenance")
        #expect(HostNavigationCatalog.route(extensionID: "keepAwake") == nil)
    }

    @Test func sidebarAndMacUtilitiesPageShowTheSameUtilities() async throws {
        let fixture = try Fixture(active: Set(Self.utilities))
        defer { fixture.clean() }
        for id in Self.utilities { await fixture.marketplace.enable(id: id) }
        #expect(fixture.marketplace.surfaceAvailability.navigableIDs == Set(Self.utilities))
        for id in Self.utilities {
            HostIntroductions(defaults: fixture.defaults).markSeen(id)
        }
        fixture.defaults.set("utilities", forKey: AppStorageKeys.General.mainWindowSection)
        let workspace = try await render(name: "sidebar-utilities", width: 1100) {
            HostWorkspace(
                marketplace: fixture.marketplace, defaults: fixture.defaults,
                modifierFlags: { [] })
        }
        let sidebarOrder = try ["Mac Utilities", "App Updates", "Homebrew", "Cleaner", "Disk Map"]
            .map { label in try #require(frame(workspace.host, label: label), "\(label)") }
        #expect(sidebarOrder.map(\.minY) == sidebarOrder.map(\.minY).sorted(by: >))
        for label in ["Maintenance", "Packages"] {
            #expect(find(workspace.host, label: label) == nil, "\(label)")
        }
        let landing = try await render(name: "mac-utilities", width: 860) {
            HostPageContent(
                marketplace: fixture.marketplace, updater: HostUpdater(startingUpdater: false),
                permissions: HostPermissions(),
                destination: HostNavigationCatalog.page("utilities"),
                settings: .constant("general"), defaults: fixture.defaults, select: { _ in })
        }
        let opens = try ["App Updates", "Homebrew", "Cleaner", "Disk Map", "Running Apps"].map {
            title in try #require(frame(landing.host, label: "Open " + title), "\(title)")
        }
        #expect(opens.map(\.minY) == opens.map(\.minY).sorted(by: >))
        workspace.window.orderOut(nil)
        landing.window.orderOut(nil)
    }

    private func render<Content: View>(
        name: String, width: Double, @ViewBuilder content: () -> Content
    ) async throws -> (host: NSHostingView<AnyView>, window: NSWindow) {
        _ = TestWindowHost.application
        let accessibility = try HostAccessibilityFixture.enable()
        defer { for error in accessibility.restore() { Issue.record(error) } }
        let host = NSHostingView(
            rootView: AnyView(
                content()
                    .environment(\.colorScheme, .dark)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.surfaceSampleContent, true)
                    .transaction { $0.animation = nil }))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 760)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<10 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: capture, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png.write(
                to: directory.appendingPathComponent("\(name)-regular-dark.png"),
                options: .atomic)
        }
        return (host, window)
    }

    private func frame(_ host: NSView, label: String) -> CGRect? {
        let accessibility = try? HostAccessibilityFixture.enable()
        defer { _ = accessibility?.restore() }
        guard let node = find(host, label: label) else { return nil }
        return (node as AnyObject).accessibilityFrame?()
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = find(child, label: label, depth: depth + 1) { return result }
        }
        if let view = node as? NSView {
            for child in view.subviews {
                if let result = find(child, label: label, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    @MainActor private struct Fixture {
        let directory: URL
        let marketplace: HostMarketplace
        let defaults: UserDefaults

        init(active: Set<String>) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.placement-\(UUID().uuidString)",
                supportDirectory: directory)
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let packages = active.sorted().map { id in
                ExtensionPackage(
                    id: id, version: "1.0.0", hostABI: HostContract.compatibility,
                    downloadURL: URL(string: "https://example.invalid/\(id).zip")!,
                    sha256: String(repeating: "a", count: 64), downloadBytes: 128,
                    installedBytes: 128)
            }
            try FileManager.default.createDirectory(
                at: store.root, withIntermediateDirectories: true)
            for package in packages {
                try FileManager.default.createDirectory(
                    at: store.directory(for: package), withIntermediateDirectories: true)
            }
            try store.commit(packages)
            marketplace = try HostMarketplace(
                identity: identity, entries: HostIndex.bundled(), store: store,
                catalogClient: ExtensionCatalogClient(
                    url: URL(string: "https://example.invalid/catalog")!,
                    publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                    repository: MarketplaceConfiguration.repository,
                    cache: directory.appendingPathComponent("catalog.json"),
                    fetch: { _ in throw MarketplaceError.downloadFailed }),
                installer: ExtensionPackageInstaller(
                    store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                    verify: { _ in throw MarketplaceError.invalidSignature }),
                sessions: HostExtensionSessions(defaults: defaults) { package in
                    guard active.contains(package.id) else { throw HostWorkerError.rejected }
                    return HostWorker(
                        configuration: HostWorkerConfiguration(
                            identity: identity, extensionID: package.id,
                            version: package.version),
                        requestTimeout: .seconds(2),
                        engine: FixtureWorkerEngine.factory(mode: "normal"))
                })
        }

        func clean() {
            let identity = marketplace.identity
            marketplace.surfaces.navigation.shutdown()
            marketplace.surfaces.requests.shutdown()
            marketplace.surfaces.privacy.shutdown()
            UserDefaults(suiteName: identity.identifier)?.removePersistentDomain(
                forName: identity.identifier)
            UserDefaults(suiteName: identity.defaultsSuite)?.removePersistentDomain(
                forName: identity.defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
