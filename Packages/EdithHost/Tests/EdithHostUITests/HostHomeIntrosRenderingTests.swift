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

@MainActor @Suite(.serialized) struct HostHomeIntrosRenderingTests {
    @MainActor final class Windows {
        private var open: [NSWindow] = []
        func keep(_ window: NSWindow) { open.append(window) }
        func close() {
            for window in open { window.orderOut(nil); window.close() }
            open.removeAll()
        }
    }

    let windows = Windows()

    struct Variant {
        let name: String
        let width: Double
        let height: Double
        let zoom: Double
        let scheme: ColorScheme

        static let all = [
            Variant(name: "regular-light", width: 1100, height: 760, zoom: 1, scheme: .light),
            Variant(name: "regular-dark", width: 1100, height: 760, zoom: 1, scheme: .dark),
            Variant(name: "compact-light", width: 640, height: 700, zoom: 1, scheme: .light),
            Variant(name: "compact-dark", width: 640, height: 700, zoom: 1, scheme: .dark),
            Variant(name: "zoom-light", width: 1100, height: 760, zoom: 1.6, scheme: .light),
        ]
    }

    @Test func homeGetStartedRendersFirstRunAndProgressEverywhere() async throws {
        defer { windows.close() }
        for stage in ["first-run", "progress"] {
            let fixture = try Fixture(installed: stage == "first-run" ? [] : ["calendar", "emoji"])
            defer { fixture.clean() }
            if stage == "progress" {
                fixture.defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
                fixture.defaults.set(true, forKey: HostSettingsCatalog.getStartedTriedKey)
            }
            let permissions = fixture.permissions()
            await permissions.refresh()
            for variant in Variant.all {
                let host = try await render(variant, name: "home-\(stage)") {
                    detail(fixture, permissions: permissions, page: "home", scheme: variant.scheme)
                }
                if stage == "first-run" {
                    try expectInside(host, labels: ["Continue setup", "Browse extensions", "Hide"])
                    #expect(find(host, label: "Add widgets") == nil)
                } else {
                    try expectInside(host, labels: variant.zoom == 1 ? ["Copy setup command", "Hide"] : ["Hide"])
                    #expect(find(host, label: "Browse extensions") == nil)
                    #expect(find(host, label: "Continue setup") == nil)
                }
            }
        }
    }

    @Test func dismissedGetStartedLeavesAnOrientedEmptyHome() async throws {
        defer { windows.close() }
        let fixture = try Fixture(installed: [])
        defer { fixture.clean() }
        fixture.defaults.set(true, forKey: HostSettingsCatalog.getStartedDismissedKey)
        let permissions = fixture.permissions()
        await permissions.refresh()
        for variant in [Variant.all[0], Variant.all[3]] {
            let host = try await render(variant, name: "home-dismissed") {
                detail(fixture, permissions: permissions, page: "home", scheme: variant.scheme)
            }
            #expect(find(host, label: "Hide") == nil)
            #expect(find(host, label: "Continue setup") == nil)
            try expectInside(host, labels: ["Browse extensions"])
        }
    }

    @Test func introductionAndReopenButtonSitInTheTitlebarStrip() async throws {
        defer { windows.close() }
        let fixture = try Fixture(installed: ["calendar"], active: ["calendar"])
        defer { fixture.clean() }
        await fixture.marketplace.enable(id: "calendar")
        #expect(fixture.marketplace.surfaceAvailability.navigableIDs.contains("calendar"))
        fixture.defaults.set("calendar", forKey: AppStorageKeys.General.mainWindowSection)
        for variant in Variant.all {
            fixture.defaults.removeObject(forKey: HostSettingsCatalog.introductionsSeenKey)
            let intro = try await render(variant, name: "intro-calendar", workspace: true) {
                workspace(fixture)
            }
            #expect(find(intro, label: "About Calendar") == nil)
            if variant.width > 1000, variant.zoom == 1 {
                try expectInside(intro, labels: ["Get started", "Skip all introductions"])
            }
            HostIntroductions(defaults: fixture.defaults).markSeen("calendar")
            let seen = try await render(variant, name: "intro-dismissed", workspace: true) {
                workspace(fixture)
            }
            #expect(find(seen, label: "Skip all introductions") == nil)
            let toggle = try #require(frame(seen, label: "Toggle sidebar"))
            let about = try #require(frame(seen, label: "About Calendar"))
            let window = try #require(seen.window)
            let top = window.convertToScreen(seen.convert(seen.bounds, to: nil)).maxY
            let strip = HostTitlebarMetrics.stripHeight * variant.zoom
            #expect(about.minY >= top - strip - 0.5)
            #expect(about.maxY <= top + 0.5)
            #expect(abs(about.midY - toggle.midY) <= 1)
        }
    }

    @Test func suiteLandingRendersInstalledAvailableAndError() async throws {
        defer { windows.close() }
        let fixture = try Fixture(installed: ["emoji", "focusDim"])
        defer { fixture.clean() }
        let permissions = fixture.permissions()
        for variant in Variant.all {
            let host = try await render(variant, name: "suite-desk") {
                detail(fixture, permissions: permissions, page: "desk", scheme: variant.scheme)
            }
            try expectInside(host, labels: ["Get Clipboard"])
        }
    }

    @Test func generalSettingsRenderIntroductionControls() async throws {
        defer { windows.close() }
        let fixture = try Fixture(installed: [])
        defer { fixture.clean() }
        let permissions = fixture.permissions()
        await permissions.refresh()
        for variant in Variant.all {
            let host = try await render(variant, name: "settings-general") {
                HostSettingsPage(
                    marketplace: fixture.marketplace, permissions: permissions,
                    defaults: fixture.defaults, showWelcome: {}, activation: { _ in })
            }
            try expectInside(host, labels: ["Introduce extensions the first time you open them", "Reset introductions"])
        }
    }

    @Test func sidebarFooterKeepsMusicAboveTheStatusLine() async throws {
        defer { windows.close() }
        let fixture = try Fixture(
            installed: ["keepAwake", "lidAwake", "system", "keystrokeHighlight"],
            active: ["keepAwake", "lidAwake", "system", "keystrokeHighlight"])
        defer { fixture.clean() }
        for id in ["keepAwake", "lidAwake", "system", "keystrokeHighlight"] {
            await fixture.marketplace.enable(id: id)
        }
        let permissions = fixture.permissions()
        await permissions.refresh()
        for music in [false, true] {
            for scheme in [ColorScheme.light, .dark] {
                let variant = Variant(
                    name: (music ? "music-" : "plain-") + (scheme == .dark ? "dark" : "light"),
                    width: 230, height: 360, zoom: 1, scheme: scheme)
                let host = try await render(variant, name: "sidebar-footer") {
                    sidebarFooter(fixture, permissions: permissions, music: music)
                }
                let status = try #require(frame(host, label: "Background agent"))
                let keep = try #require(frame(host, label: "Keep awake"))
                #expect(keep.minY >= status.maxY)
                if music {
                    let player = try #require(frame(host, label: "Synthetic player"))
                    #expect(player.minY >= keep.maxY)
                }
            }
        }
    }

    private func detail(
        _ fixture: Fixture, permissions: HostPermissions, page: String,
        scheme: ColorScheme
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

    private func workspace(_ fixture: Fixture) -> some View {
        HostWorkspace(
            marketplace: fixture.marketplace, defaults: fixture.defaults, modifierFlags: { [] })
    }

    private func sidebarFooter(
        _ fixture: Fixture, permissions: HostPermissions, music: Bool
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HostSidebarFooter(
                marketplace: fixture.marketplace, updater: HostUpdater(startingUpdater: false),
                permissions: permissions, theme: .accentColor, sidebarWidth: 230, presenter: nil,
                openExtensions: {}, openPermissions: {}, enabled: false,
                music: music
                    ? AnyView(
                        RoundedRectangle(cornerRadius: UIScale.pt(10))
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: UIScale.pt(46))
                            .accessibilityElement()
                            .accessibilityLabel("Synthetic player"))
                    : nil)
            HostAgentStatusBar(online: true, summary: "collecting 4 sources") {}
        }
        .background(HostSidebarMaterial())
    }

    private func render<Content: View>(
        _ variant: Variant, name: String, workspace: Bool = false,
        @ViewBuilder content: () -> Content
    ) async throws -> NSHostingView<AnyView> {
        _ = TestWindowHost.application
        let previous = UIScale.current
        UIScale.apply(variant.zoom)
        defer { UIScale.apply(previous) }
        let accessibility = try HostAccessibilityFixture.enable()
        defer { for error in accessibility.restore() { Issue.record(error) } }
        let host = NSHostingView(
            rootView: AnyView(
                content()
                    .environment(\.compactLayout, !workspace && variant.width < UIScale.pt(720))
                    .environment(\.colorScheme, variant.scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.surfaceSampleContent, true)
                    .transaction { $0.animation = nil }))
        host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(x: 0, y: 0, width: variant.width, height: variant.height)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<8 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: capture, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(
                to: directory.appendingPathComponent("\(name)-\(variant.name).png"),
                options: .atomic)
        }
        windows.keep(window)
        return host
    }

    private func expectInside(_ host: NSView, labels: [String]) throws {
        let window = try #require(host.window)
        let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
        for label in labels {
            let control = try #require(frame(host, label: label), "\(label)")
            #expect(visible.insetBy(dx: -1, dy: -1).contains(control), "\(label)")
            #expect(control.width > 1 && control.height > 1, "\(label)")
        }
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
        let valueSelector = NSSelectorFromString("accessibilityValue")
        if node.responds(to: valueSelector),
            node.perform(valueSelector)?.takeUnretainedValue() as? String == label
        {
            return node
        }
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

        init(installed: [String], active: Set<String> = []) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.home-intros-\(UUID().uuidString)",
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
            let key = Curve25519.Signing.PrivateKey()
            let cache = directory.appendingPathComponent("catalog.json")
            marketplace = try HostMarketplace(
                identity: identity, entries: HostIndex.bundled(), store: store,
                catalogClient: ExtensionCatalogClient(
                    url: URL(string: "https://example.invalid/catalog")!,
                    publicKey: key.publicKey.rawRepresentation,
                    repository: MarketplaceConfiguration.repository, cache: cache,
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
