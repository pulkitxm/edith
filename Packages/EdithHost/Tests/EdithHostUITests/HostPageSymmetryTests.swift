import AppKit
import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostPageSymmetryTests {
    private struct Variant {
        let name: String
        let width: Double
        let height: Double
        let zoom: Double
        let scheme: ColorScheme

        static let all = [
            Variant(name: "regular", width: 1100, height: 760, zoom: 1, scheme: .light),
            Variant(name: "wide", width: 1600, height: 960, zoom: 1, scheme: .light),
            Variant(name: "wide-dark", width: 1600, height: 960, zoom: 1, scheme: .dark),
            Variant(name: "compact", width: 640, height: 700, zoom: 1, scheme: .light),
            Variant(name: "zoomed", width: 1100, height: 760, zoom: 1.6, scheme: .light),
        ]
    }

    @Test func settingsPanesShareTheHeaderColumn() async throws {
        let fixture = try Fixture(installed: ["emoji", "focusDim", "calendar"])
        defer { fixture.clean() }
        let permissions = fixture.permissions()
        await permissions.refresh()
        let services = try HostCoreServices(
            identity: fixture.marketplace.identity, marketplace: fixture.marketplace,
            togglePanel: {})
        for variant in Variant.all {
            let general = try await render(variant, name: "settings-general") {
                settings("general") {
                    HostSettingsPage(
                        marketplace: fixture.marketplace, permissions: permissions,
                        defaults: fixture.defaults, showWelcome: {}, activation: { _ in })
                }
            }
            expectBalanced(general, variant)
            let shortcuts = try await render(variant, name: "settings-shortcuts") {
                settings("shortcuts") { HostShortcutsPane(marketplace: fixture.marketplace) }
            }
            expectBalanced(shortcuts, variant)
            try await render(variant, name: "settings-updates") {
                settings("updates") {
                    HostUpdatesPane(updater: HostUpdater(startingUpdater: false))
                }
            }
            let cloud = try await render(variant, name: "settings-cloud") {
                settings("icloud") { HostCloudPage(services: services) }
            }
            expectBalanced(cloud, variant)
            let data = try await render(variant, name: "settings-data") {
                settings("data") { HostDataPage(services: services) }
            }
            expectBalanced(data, variant)
            let terminal = try await render(variant, name: "settings-terminal") {
                settings("terminal") { HostToolingSettingsPage(defaults: fixture.defaults) }
            }
            expectBalanced(terminal, variant)
            try await render(variant, name: "settings-permissions") {
                settings("permissions") {
                    HostPermissionsList(
                        usages: permissions.usages(
                            entries: fixture.marketplace.entries,
                            activeIDs: ["calendar", "emoji", "focusDim"]),
                        permissions: permissions, filter: .constant(.all))
                }
            }
            try await render(variant, name: "settings-permissions-empty") {
                settings("permissions") {
                    HostPermissionsList(
                        usages: [], permissions: permissions, filter: .constant(.all))
                }
            }
            try await render(variant, name: "settings-storage") {
                settings("storage") { HostStoragePage(marketplace: fixture.marketplace) }
            }
        }
    }

    @Test func standalonePagesStayBalanced() async throws {
        let fixture = try Fixture(installed: ["emoji", "focusDim", "calendar"])
        defer { fixture.clean() }
        let permissions = fixture.permissions()
        await permissions.refresh()
        for variant in Variant.all {
            for page in ["home", "desk", "agents", "system", "media", "data", "about", "extensions"]
            {
                try await render(variant, name: "page-\(page)") {
                    detail(fixture, permissions: permissions, page: page, scheme: variant.scheme)
                }
            }
        }
    }

    private func expectBalanced(_ bitmap: NSBitmapImageRep, _ variant: Variant) {
        guard let paper = bitmap.colorAt(x: 2, y: bitmap.pixelsHigh - 2) else { return }
        func inked(_ x: Int) -> Bool {
            stride(from: 0, to: bitmap.pixelsHigh, by: 3).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                return abs(color.redComponent - paper.redComponent) > 0.015
                    || abs(color.greenComponent - paper.greenComponent) > 0.015
                    || abs(color.blueComponent - paper.blueComponent) > 0.015
            }
        }
        let columns = 0..<bitmap.pixelsWide
        let scale = Double(bitmap.pixelsWide) / variant.width
        let left = Double(columns.first(where: inked) ?? 0) / scale
        let last = columns.last(where: inked) ?? bitmap.pixelsWide - 1
        let right = variant.width - Double(last + 1) / scale
        let compact = variant.width < 720 * variant.zoom
        let gutter = (compact ? PageMetrics.compactGutter : PageMetrics.gutter) * variant.zoom
        let column = min(
            PageMetrics.formWidth * variant.zoom, PageMetrics.formWidth + 2 * gutter)
        let edge = max(0, variant.width - column) / 2 + gutter
        #expect(abs(left - edge) <= 2, "\(variant.name) left \(left) edge \(edge)")
        #expect(abs(right - edge) <= 2, "\(variant.name) right \(right) edge \(edge)")
    }

    private func settings<Content: View>(
        _ id: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        HostSettingsContainer(category: .constant(id), content: content)
    }

    private func detail(
        _ fixture: Fixture, permissions: HostPermissions, page: String, scheme: ColorScheme
    ) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(DashSkin.paper(scheme == .dark))
                .frame(height: UIScale.pt(HostTitlebarMetrics.stripHeight))
            HostPageContent(
                marketplace: fixture.marketplace, updater: HostUpdater(startingUpdater: false),
                permissions: permissions, destination: HostNavigationCatalog.page(page),
                settings: .constant("general"), maintenanceSection: .constant("Updates"),
                showWelcome: {}, defaults: fixture.defaults, select: { _ in })
        }
    }

    @discardableResult
    private func render<Content: View>(
        _ variant: Variant, name: String, @ViewBuilder content: () -> Content
    ) async throws -> NSBitmapImageRep {
        _ = TestWindowHost.application
        let previous = UIScale.current
        UIScale.apply(variant.zoom)
        defer { UIScale.apply(previous) }
        let host = NSHostingView(
            rootView: AnyView(
                content()
                    .environment(\.compactLayout, variant.width < UIScale.pt(720))
                    .environment(\.colorScheme, variant.scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.surfaceSampleContent, true)
                    .transaction { $0.animation = nil }))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(x: 0, y: 0, width: variant.width, height: variant.height)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<8 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: capture, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: directory.appendingPathComponent("\(name)-\(variant.name).png"),
                options: .atomic)
        }
        return bitmap
    }

    @MainActor private struct Fixture {
        let directory: URL
        let marketplace: HostMarketplace
        let defaults: UserDefaults

        init(installed: [String]) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.symmetry-\(UUID().uuidString)",
                supportDirectory: directory)
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let packages = installed.map { id in
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
            if !packages.isEmpty { try store.commit(packages) }
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
                sessions: HostExtensionSessions(defaults: defaults) { _ in
                    throw HostWorkerError.rejected
                })
        }

        func permissions() -> HostPermissions {
            HostPermissions(
                environment: HostPermissionEnvironment(
                    read: {
                        [
                            .calendar: false, .notifications: true, .accessibility: true,
                            .inputMonitoring: false, .fullDisk: false, .screenRecording: false,
                            .camera: false,
                        ]
                    }, request: { _ in }, openSettings: { _ in false }),
                defaults: defaults, recordPrompt: {}, relaunch: {})
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
