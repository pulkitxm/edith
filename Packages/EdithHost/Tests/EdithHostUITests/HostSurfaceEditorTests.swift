import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized) struct HostSurfaceEditorTests {
    @Test func emptyHomeRendersOnlyTheBuiltInClockAndOffersExtensionDiscovery() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: HostHomePage(marketplace: fixture.marketplace, customize: {}, extensions: {})
                .environment(\.compactLayout, false).environment(
                    \.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "World clocks") != nil)
        #expect(find(host, label: "Customize") != nil)
        #expect(find(host, label: "Extensions") != nil)
        #expect(find(host, label: "Meetings") == nil)
        #expect(find(host, label: "Open Calendar") == nil)
        #expect(fixture.marketplace.surfaces.requests.pendingCount == 0)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test func sharedCardRendererShowsRealContractDataAndDispatchesOnlyItsActionID() async throws {
        let restore = enableAccessibility()
        defer { restore() }
        let action = SurfaceAction("join:synthetic-meeting", "Join", "video.fill", field: "join")
        let snapshot = SurfaceSnapshot(
            providerID: "calendar",
            rows: [
                .init(
                    "synthetic-meeting", sourceID: "synthetic-calendar",
                    title: "Synthetic design review", detail: "Synthetic calendar", value: "10:00",
                    icon: "calendar", actions: [action])
            ])
        var performed: [String] = []
        let host = NSHostingView(
            rootView: SurfaceSnapshotContent(
                tile: .init(.calendar), snapshot: snapshot, perform: { performed.append($0.id) }
            ).padding(16).frame(width: 420))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 240)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "Synthetic design review") != nil)
        let join = try #require(find(host, label: "Join"))
        #expect((join as AnyObject).accessibilityPerformPress?() == true)
        #expect(performed == ["join:synthetic-meeting"])
        var hidden = SurfaceTile(.calendar)
        hidden.hiddenFields = ["join"]
        let restricted = NSHostingView(
            rootView: SurfaceSnapshotContent(
                tile: hidden, snapshot: snapshot,
                perform: { _ in Issue.record("Hidden action was executed") }))
        restricted.frame = host.frame
        window.contentView = restricted
        await settle(window, host: restricted)
        #expect(find(restricted, label: "Join") == nil)
    }

    @Test func selectingAWidgetRetainsCanvasGeometryAndNeverStartsAnExtension() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let editor = HostSurfaceEditor(marketplace: fixture.marketplace)
        let host = NSHostingView(
            rootView: editor.environment(\.compactLayout, false)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        let first = try #require(find(host, label: "Move World clocks"))
        let before = try #require((first as AnyObject).accessibilityFrame?())
        fixture.marketplace.surfaces.preferences.set("clocks", forKey: "surfaceEditorWidget")
        await settle(window, host: host)
        let selected = try #require(find(host, label: "Move World clocks"))
        let after = try #require((selected as AnyObject).accessibilityFrame?())
        #expect(find(host, label: "Lock layout") != nil)
        #expect(abs(before.minX - after.minX) < 1)
        #expect(abs(before.width - after.width) < 1)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    @Test func addingADownloadableWidgetSavesItsLayoutWithoutDownloadingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        fixture.marketplace.surfaceLayouts.update(.home) { $0.tiles = [] }
        let host = NSHostingView(
            rootView: HostSurfaceEditor(marketplace: fixture.marketplace)
                .environment(\.compactLayout, false)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        let add = try #require(find(host, label: "Add Meetings"))
        #expect((add as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.surfaceLayouts.home.tiles.map(\.widget) == [.calendar])
        #expect(find(host, label: "Download") != nil)
        let restored = SurfaceLayoutStore(defaults: fixture.marketplace.surfaces.preferences)
        #expect(restored.home == fixture.marketplace.surfaceLayouts.home)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test func bothEditorsRenderAtCompactRegularAndZoomedSizes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        for target in SurfaceTarget.allCases {
            fixture.marketplace.surfaces.preferences.set(
                target.rawValue, forKey: "surfaceEditorTarget")
            for variant in [
                Variant("regular-light", 1200, 1, .light), Variant("regular-dark", 1200, 1, .dark),
                Variant("compact", 620, 1, .light), Variant("zoomed", 1200, 1.5, .dark),
            ] {
                UIScale.apply(variant.zoom)
                let host = NSHostingView(
                    rootView: HostSurfaceEditor(marketplace: fixture.marketplace)
                        .environment(\.compactLayout, variant.width < UIScale.pt(720))
                        .environment(\.colorScheme, variant.scheme)
                        .environment(\.automaticViewActionsEnabled, false)
                        .transaction { $0.animation = nil })
                host.frame = CGRect(x: 0, y: 0, width: variant.width, height: 900)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentView = host
                window.orderBack(nil)
                await settle(window, host: host)
                #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                #expect(abs(host.bounds.width - variant.width) < 1)
                let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
                for label in ["Home", "Notch", "Grid", "Layouts"] {
                    let control = try #require(find(host, label: label))
                    let frame = try #require((control as AnyObject).accessibilityFrame?())
                    #expect(visible.insetBy(dx: -1, dy: -1).contains(frame))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
                {
                    let directory = URL(fileURLWithPath: capture, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: directory.appendingPathComponent(
                            "\(target.rawValue)-\(variant.name).png"), options: .atomic)
                }
                #expect(!TestWindowHost.isExposedOnDesktop(window))
                window.orderOut(nil)
            }
        }
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    private struct Variant {
        let name: String
        let width: Double
        let zoom: Double
        let scheme: ColorScheme
        init(_ name: String, _ width: Double, _ zoom: Double, _ scheme: ColorScheme) {
            self.name = name; self.width = width; self.zoom = zoom; self.scheme = scheme
        }
    }

    @Test(arguments: [true, false])
    func pendingDisableExplainsInactiveCardsAndOffersExplicitRecoveryActions(compact: Bool)
        async throws
    {
        let fixture = try Fixture(pendingDisableID: "calendar")
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: MarketplacePage(marketplace: fixture.marketplace)
                .frame(width: compact ? 600 : 1100, height: 650)
                .environment(\.compactLayout, compact).environment(
                    \.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: compact ? 600 : 1100, height: 650)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "Disable pending · 1.0.0") != nil)
        #expect(find(host, label: "Enabled · 1.0.0") == nil)
        #expect(find(host, label: "Disabled · 1.0.0") == nil)
        #expect(
            find(
                host,
                label:
                    "Cleanup is still pending. Home and Notch cards are inactive. System resources may remain until cleanup or macOS approval finishes."
            ) != nil)
        let retry = try #require(find(host, label: "Retry disable"))
        #expect((retry as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.sessions.pendingDisableIDs == ["calendar"])
        #expect(fixture.marketplace.error != nil)
        #expect(fixture.marketplace.surfaceAvailability.activeIDs.isEmpty)
        let enable = try #require(find(host, label: "Enable instead"))
        #expect((enable as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.sessions.pendingDisableIDs == ["calendar"])
        #expect(fixture.marketplace.sessions.states["calendar"] == .failed)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(find(host, label: "Disable pending · 1.0.0") != nil)
        #expect(find(host, label: "Retry disable") != nil)
        #expect(fixture.marketplace.error?.contains("Cleanup is pending") == true)
        #expect(fixture.marketplace.surfaceAvailability.activeIDs.isEmpty)
        #expect(await fixture.requests.count == 0)
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

    private func enableAccessibility() -> () -> Void {
        _ = TestWindowHost.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        return {
            for (attribute, value) in zip(attributes, previous) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
    }

    private func settle(_ window: NSWindow, host: NSView) async {
        for _ in 0..<8 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private actor Requests {
        private(set) var count = 0
        func reject() throws -> Data {
            count += 1
            throw MarketplaceError.downloadFailed
        }
    }

    @MainActor private struct Fixture {
        let directory: URL
        let marketplace: HostMarketplace
        let requests = Requests()

        init(pendingDisableID: String? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.surface-editor-\(UUID().uuidString)",
                supportDirectory: directory)
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            if let id = pendingDisableID {
                try FileManager.default.createDirectory(
                    at: store.root, withIntermediateDirectories: true)
                defaults.set([id], forKey: "enabledExtensions")
                defaults.set([id], forKey: "pendingDisableExtensions")
                try store.commit([
                    ExtensionPackage(
                        id: id, version: "1.0.0", hostABI: HostContract.compatibility,
                        downloadURL: URL(
                            string:
                                "https://github.com/pulkitxm/edith/releases/download/synthetic/fixture.zip"
                        )!,
                        sha256: String(repeating: "a", count: 64), downloadBytes: 1,
                        installedBytes: 1)
                ])
            }
            let sessions = HostExtensionSessions(defaults: defaults) { _ in
                throw HostWorkerError.rejected
            }
            let client = ExtensionCatalogClient(
                url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                publicKey: Data(repeating: 0, count: 32),
                repository: MarketplaceConfiguration.repository,
                cache: directory.appendingPathComponent("catalog.json"),
                fetch: { [requests] _ in try await requests.reject() })
            let installer = ExtensionPackageInstaller(
                store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                verify: { _ in throw MarketplaceError.invalidSignature })
            marketplace = try HostMarketplace(
                identity: identity,
                entries: try HostIndex.bundled().filter {
                    pendingDisableID == nil || $0.id == pendingDisableID
                }, store: store,
                catalogClient: client, installer: installer, sessions: sessions)
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
