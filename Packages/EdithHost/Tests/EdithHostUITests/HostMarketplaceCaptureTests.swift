import AppKit
import CryptoKit
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import Foundation
import HostAccessibilityFixtureSupport
import HostWorkerFixtureSupport
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostMarketplaceCaptureTests {
    private struct Variant {
        let name: String
        let size: CGSize
        let zoom: Double
        let scheme: ColorScheme

        static let regularLight = Variant(
            name: "regular-light", size: .init(width: 1100, height: 760), zoom: 1, scheme: .light)
        static let regularDark = Variant(
            name: "regular-dark", size: .init(width: 1100, height: 760), zoom: 1, scheme: .dark)
        static let compactLight = Variant(
            name: "compact-light", size: .init(width: 640, height: 700), zoom: 1, scheme: .light)
        static let compactDark = Variant(
            name: "compact-dark", size: .init(width: 640, height: 700), zoom: 1, scheme: .dark)
        static let zoomed = Variant(
            name: "zoomed", size: .init(width: 1100, height: 760), zoom: 1.6, scheme: .dark)
        static let page = [regularLight, regularDark, compactLight, compactDark, zoomed]
    }

    @Test func storefrontRendersFirstRunWithRecommendedAndGetButtons() async throws {
        let fixture = try StorefrontFixture()
        defer { fixture.clean() }
        await fixture.marketplace.loadCachedCatalog()
        let restore = try enableAccessibility()
        defer { restore() }
        for variant in Variant.page {
            let host = try await capture(
                MarketplacePage(marketplace: fixture.marketplace), name: "page-first-run",
                variant: variant)
            #expect(find(host, label: "Recommended") != nil)
            #expect(find(host, label: "Get Agents") != nil)
            #expect(find(host, label: "Agents & Terminal suite enabled") == nil)
            if variant.zoom == 1 { try expectVisible(host, labels: ["Get Usage", "Find extensions"]) }
        }
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
    }

    @Test func storefrontRendersEveryInstallStageInPlace() async throws {
        let fixture = try StorefrontFixture(
            installed: ["usage": "1.1.0", "clipboard": "1.1.0", "keepAwake": "1.0.0"],
            stalledIDs: ["herdr"])
        defer { fixture.clean() }
        try await fixture.prepareStages()
        let restore = try enableAccessibility()
        defer { restore() }
        for variant in Variant.page {
            let host = try await capture(
                MarketplacePage(marketplace: fixture.marketplace), name: "page-stages",
                variant: variant)
            #expect(find(host, label: "Agents & Terminal suite enabled") != nil)
            #expect(find(host, label: "Find it in the sidebar as Usage.") != nil)
            for label in ["Open Usage", "Retry Launcher", "Cancel installing Agents"] {
                #expect(find(host, label: label) != nil, "\(label)")
            }
            if variant.size.width > 1000, variant.zoom == 1 {
                try expectVisible(host, labels: ["Retry Launcher", "Cancel installing Agents"])
            }
        }
        let full = try await capture(
            MarketplacePage(marketplace: fixture.marketplace), name: "page-stages-full",
            variant: .init(
                name: "regular-light", size: .init(width: 1100, height: 3000), zoom: 1,
                scheme: .light))
        try expectVisible(full, labels: ["Update Keep Awake", "Update extensions automatically"])
        _ = try await capture(
            MarketplacePage(marketplace: fixture.marketplace), name: "page-stages-full",
            variant: .init(
                name: "compact-dark", size: .init(width: 640, height: 5200), zoom: 1,
                scheme: .dark))
        fixture.marketplace.cancelDownload(id: "herdr")
    }

    @Test func storefrontShowsSkeletonsWhileTheCatalogLoads() async throws {
        let fixture = try StorefrontFixture(catalog: .stalled)
        defer { fixture.clean() }
        let refresh = Task { await fixture.marketplace.checkForUpdates() }
        defer { refresh.cancel() }
        try await waitUntil { fixture.marketplace.refreshingCatalog }
        let restore = try enableAccessibility()
        defer { restore() }
        for variant in [Variant.regularLight, .compactDark] {
            let host = try await capture(
                MarketplacePage(marketplace: fixture.marketplace), name: "page-loading",
                variant: variant)
            #expect(find(host, label: "Loading extensions") != nil)
        }
    }

    @Test func storefrontExplainsAnUnreachableCatalogWithARetry() async throws {
        let fixture = try StorefrontFixture(catalog: .unreachable)
        defer { fixture.clean() }
        await fixture.marketplace.checkForUpdates()
        #expect(fixture.marketplace.error != nil)
        let restore = try enableAccessibility()
        defer { restore() }
        for variant in [Variant.regularLight, .regularDark, .compactLight] {
            let host = try await capture(
                MarketplacePage(marketplace: fixture.marketplace), name: "page-error",
                variant: variant)
            try expectVisible(host, labels: ["Try Again"])
            #expect(find(host, label: "Extensions could not load") != nil)
            #expect(count(host, label: fixture.marketplace.error ?? "") == 0)
        }
    }

    @Test func detailPagesRenderEveryStageWithOnePrimaryAction() async throws {
        let fixture = try StorefrontFixture(
            installed: [
                "usage": "1.1.0", "clipboard": "1.1.0", "keepAwake": "1.0.0", "machines": "1.1.0",
            ],
            stalledIDs: ["herdr"])
        defer { fixture.clean() }
        try await fixture.prepareStages()
        await fixture.marketplace.enable(id: "machines")
        fixture.marketplace.markReady("machines")
        let restore = try enableAccessibility()
        defer { restore() }
        let cases: [(id: String, stage: String, action: String)] = [
            ("hinge", "not-installed", "Get Hinge"),
            ("music", "not-installed", "Get Music"),
            ("herdr", "downloading", "Cancel installing Agents"),
            ("usage", "ready", "Open Usage"),
            ("machines", "ready", "Open Machines"),
            ("keepAwake", "update", "Update Keep Awake"),
            ("bifrost", "failed", "Retry Launcher"),
        ]
        for item in cases {
            let entry = try #require(fixture.marketplace.entries.first { $0.id == item.id })
            for variant in [Variant.regularLight, .regularDark] {
                let host = try await capture(
                    detail(entry, fixture: fixture), name: "detail-\(item.id)-\(item.stage)",
                    variant: variant, sheet: true)
                try expectVisible(host, labels: [item.action, "Close"])
                if item.stage == "failed" {
                    #expect(count(host, label: "The extension could not be downloaded. Try again.") == 1)
                }
                if item.stage == "ready" {
                    #expect(find(host, label: "\(entry.title) is ready") != nil || item.id == "usage")
                }
            }
        }
        let hinge = try #require(fixture.marketplace.entries.first { $0.id == "hinge" })
        let zoomed = try await capture(
            detail(hinge, fixture: fixture), name: "detail-hinge-not-installed", variant: .zoomed,
            sheet: true)
        try expectVisible(zoomed, labels: ["Get Hinge", "Close"])
        let usage = try #require(fixture.marketplace.entries.first { $0.id == "usage" })
        let header = try await capture(
            detail(usage, fixture: fixture), name: "detail-usage-ready", variant: .zoomed,
            sheet: true)
        try expectVisible(header, labels: ["Open Usage", "Usage enabled", "Close"])
        fixture.marketplace.cancelDownload(id: "herdr")
    }

    @Test func detailSectionsBelowTheFoldRenderPermissionsAndExamples() async throws {
        let entry = try #require(
            try HostIndex.bundled().first {
                !($0.requiredPermissions + $0.optionalPermissions).isEmpty
                    && $0.guide?.examples.isEmpty == false
            })
        let example = try #require(entry.guide?.examples.first)
        let restore = try enableAccessibility()
        defer { restore() }
        for variant in [Variant.regularLight, .regularDark] {
            let sections = VStack(
                alignment: .leading, spacing: HostExtensionDetailLayout.sectionSpacing
            ) {
                HostExtensionPlacementList(placements: HostExtensionActions.placements(for: entry))
                HostExtensionPermissionList(
                    required: entry.requiredPermissions, optional: entry.optionalPermissions)
                HostExtensionExamples(examples: entry.guide?.examples ?? [])
            }
            .padding(HostExtensionDetailLayout.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DashSkin.paper(variant.scheme == .dark))
            let host = try await capture(
                sections, name: "detail-sections",
                variant: .init(
                    name: variant.name, size: .init(width: 640, height: 900), zoom: 1,
                    scheme: variant.scheme))
            #expect(find(host, label: "Permissions") != nil)
            #expect(find(host, label: example) != nil)
        }
    }

    @Test func everyDetailArtworkFillsItsBanner() async throws {
        let entries = try HostIndex.bundled().filter { HostExtensionPreview.hasPreview($0.id) }
        #expect(entries.count == HostExtensionPreview.previewIDs.count)
        for variant in [Variant.regularLight, .regularDark] {
            let gallery = LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(592), spacing: 16), count: 2), spacing: 16
            ) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.id).font(.caption)
                        HostExtensionArtwork(entry: entry)
                    }
                }
            }
            .padding(16)
            .background(DashSkin.paper(variant.scheme == .dark))
            let rows = (entries.count + 1) / 2
            _ = try await capture(
                gallery, name: "artwork-gallery",
                variant: .init(
                    name: variant.name, size: .init(width: 1232, height: Double(rows) * 214 + 32),
                    zoom: 1, scheme: variant.scheme))
        }
    }

    private func detail(_ entry: HostExtension, fixture: StorefrontFixture) -> some View {
        HostExtensionReview(
            marketplace: fixture.marketplace,
            suites: HostSuiteSelection(marketplace: fixture.marketplace, defaults: fixture.defaults),
            entry: entry, presenter: nil, open: {}, done: {})
    }

    private func capture<V: View>(
        _ view: V, name: String, variant: Variant, sheet: Bool = false
    ) async throws -> NSHostingView<AnyView> {
        let previous = UIScale.current
        UIScale.apply(variant.zoom)
        defer { UIScale.apply(previous) }
        let size =
            sheet
            ? CGSize(width: PresentationMetrics.width(640), height: PresentationMetrics.height(680))
            : variant.size
        let host = NSHostingView(
            rootView: AnyView(
                view
                    .environment(\.compactLayout, !sheet && size.width < UIScale.pt(720))
                    .environment(\.colorScheme, variant.scheme)
                    .environment(\.controlActiveState, .key)
                    .environment(\.automaticViewActionsEnabled, false)
                    .transaction { $0.animation = nil }))
        host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        #expect(abs(host.bounds.width - size.width) < 1)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: folder.appendingPathComponent("\(name)-\(variant.name).png"), options: .atomic)
        }
        return host
    }

    private func expectVisible(_ host: NSView, labels: [String]) throws {
        guard let window = host.window else { return }
        let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
        for label in labels {
            let control = try #require(find(host, label: label), "\(label)")
            let frame = try #require((control as AnyObject).accessibilityFrame?())
            #expect(visible.insetBy(dx: -1, dy: -1).contains(frame), "\(label) \(frame)")
        }
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if matches(node, label: label) { return node }
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

    private func matches(_ node: NSObject, label: String) -> Bool {
        if (node as AnyObject).accessibilityLabel?() == label { return true }
        let value = NSSelectorFromString("accessibilityValue")
        return node.responds(to: value)
            && node.perform(value)?.takeUnretainedValue() as? String == label
    }

    private func count(_ node: NSObject, label: String, depth: Int = 0) -> Int {
        guard depth < 64 else { return 0 }
        var total = matches(node, label: label) ? 1 : 0
        var children = (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
        if children.isEmpty, let view = node as? NSView { children = view.subviews }
        for child in children { total += count(child, label: label, depth: depth + 1) }
        return total
    }

    private func enableAccessibility() throws -> () -> Void {
        _ = TestWindowHost.application
        let accessibility = try HostAccessibilityFixture.enable()
        return {
            for error in accessibility.restore() { Issue.record(error) }
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

@MainActor private struct StorefrontFixture {
    enum Catalog { case cached, stalled, unreachable }

    let directory: URL
    let marketplace: HostMarketplace
    let defaults: UserDefaults

    init(
        installed: [String: String] = [:], catalog: Catalog = .cached,
        stalledIDs: Set<String> = []
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "marketplace-capture-\(UUID().uuidString)")
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.marketplace-capture-\(UUID().uuidString)",
            supportDirectory: directory)
        defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let entries = try HostIndex.bundled()
        func package(_ id: String, version: String) -> ExtensionPackage {
            let size = Int64(1_200_000 + id.utf8.reduce(0) { ($0 * 31 + Int($1)) % 3_000_000 })
            return ExtensionPackage(
                id: id, version: version, hostABI: HostContract.compatibility,
                downloadURL: URL(
                    string:
                        "https://github.com/pulkitxm/edith/releases/download/synthetic-\(version)/\(id).zip"
                )!,
                sha256: String(repeating: "a", count: 64), downloadBytes: size,
                installedBytes: size * 3)
        }
        var local: [ExtensionPackage] = []
        for (id, version) in installed.sorted(by: { $0.key < $1.key }) {
            let item = package(id, version: version)
            try FileManager.default.createDirectory(
                at: store.directory(for: item), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(
                to: store.directory(for: item).appendingPathComponent("synthetic-payload"))
            local.append(item)
        }
        if !local.isEmpty { try store.commit(local) }
        let key = Curve25519.Signing.PrivateKey()
        let payload = try JSONEncoder().encode(
            ExtensionCatalog(
                revision: 1, packages: entries.map { package($0.id, version: "1.1.0") }))
        let signed = try JSONEncoder().encode(
            SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("catalog.json")
        if catalog == .cached { try signed.write(to: cache) }
        let client = ExtensionCatalogClient(
            url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
            publicKey: key.publicKey.rawRepresentation,
            repository: MarketplaceConfiguration.repository, cache: cache,
            fetch: { _ in
                switch catalog {
                case .cached: return signed
                case .stalled:
                    try await Task.sleep(for: .seconds(600))
                    throw MarketplaceError.downloadFailed
                case .unreachable: throw MarketplaceError.downloadFailed
                }
            })
        let progress = HostTransferProgress()
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { url, bytes in
                if stalledIDs.contains(url.deletingPathExtension().lastPathComponent) {
                    progress.report(url, bytes: bytes * 42 / 100)
                    try await Task.sleep(for: .seconds(600))
                }
                throw MarketplaceError.downloadFailed
            },
            verify: { _ in throw MarketplaceError.invalidSignature })
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                requestTimeout: .seconds(2), engine: FixtureWorkerEngine.factory(mode: "normal"))
        }
        marketplace = try HostMarketplace(
            identity: identity, entries: entries, store: store, catalogClient: client,
            installer: installer, sessions: sessions, transferProgress: progress)
    }

    func prepareStages() async throws {
        await marketplace.loadCachedCatalog()
        await marketplace.enable(id: "usage")
        await marketplace.enable(id: "clipboard")
        marketplace.markReady("usage")
        await marketplace.download(id: "bifrost")
        Task { await marketplace.download(id: "herdr") }
        for _ in 0..<200 where (marketplace.operations["herdr"]?.receivedBytes ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(marketplace.operations["herdr"]?.receivedBytes ?? 0 > 0)
        #expect(marketplace.failures["bifrost"] != nil)
        #expect(marketplace.surfaceAvailability.activeIDs.isSuperset(of: ["usage", "clipboard"]))
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
