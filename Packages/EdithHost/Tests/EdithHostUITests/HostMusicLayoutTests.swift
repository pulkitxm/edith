import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import ExtensionMarketplace
import Observation
import SwiftUI
import Testing

@testable import EdithHost
@testable import EdithHostCore

@MainActor
@Suite(.serialized)
struct HostMusicLayoutTests {
    @Test func originalFooterOccupiesWholeWindowBelowMainAndCollapsesAtZeroHeight() async throws {
        for width in [530.0, 1100.0] {
            let state = Height()
            let host = NSHostingView(rootView: Layout(state: state))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            await settle(host)
            let main = try #require(find(host, "main"))
            let footer = try #require(find(host, "music.footer"))
            let mainFrame = host.convert(main.bounds, from: main)
            let footerFrame = host.convert(footer.bounds, from: footer)
            #expect(abs(mainFrame.width - width) < 1)
            #expect(abs(footerFrame.width - width) < 1)
            #expect(abs(footerFrame.height - 52) < 1)
            #expect(!mainFrame.intersects(footerFrame.insetBy(dx: 1, dy: 1)))
            #expect(abs(mainFrame.height + footerFrame.height - 600) < 1)
            state.value = 0
            await settle(host)
            #expect(abs(host.convert(footer.bounds, from: footer).height) < 1)
            #expect(abs(host.convert(main.bounds, from: main).height - 600) < 1)
            #expect(host.window == nil)
        }
    }

    @Test func originalSidebarMusicAloneRetainsPaddingWithoutOtherUtilities() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for width in [180.0, 260.0] {
            let host = NSHostingView(
                rootView: HostSidebarFooter(
                    marketplace: fixture.marketplace, updater: HostUpdater(startingUpdater: false),
                    permissions: HostPermissions(), theme: .blue, sidebarWidth: width,
                    presenter: nil, openExtensions: {}, openPermissions: {},
                    music: AnyView(Marker(id: "music.sidebar", height: 46).frame(height: 46))
                ).environment(\.automaticViewActionsEnabled, false)
                    .environment(\.windowVisible, false))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 90)
            await settle(host)
            let music = try #require(find(host, "music.sidebar"))
            let frame = host.convert(music.bounds, from: music)
            #expect(abs(frame.width - (width - UIScale.pt(20))) < 1)
            #expect(frame.minX >= UIScale.pt(10) - 1)
            #expect(frame.maxX <= width - UIScale.pt(10) + 1)
            #expect(abs(frame.height - 46) < 1)
            #expect(host.window == nil)
        }
    }

    @Observable final class Height { var value = 52.0 }

    private struct Layout: View {
        let state: Height
        var body: some View {
            HostMusicWindowLayout {
                Marker(id: "main", height: nil)
            } footer: {
                Marker(id: "music.footer", height: state.value).frame(height: state.value)
            }
        }
    }

    private struct Marker: NSViewRepresentable {
        let id: String
        let height: Double?
        func makeNSView(context: Context) -> NSView {
            let view = NSView(); view.identifier = .init(id); return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize?
        {
            CGSize(
                width: proposal.width ?? 0,
                height: height.map { CGFloat($0) } ?? proposal.height ?? 0)
        }
    }

    private func find(_ root: NSView, _ id: String) -> NSView? {
        if root.identifier?.rawValue == id { return root }
        for child in root.subviews {
            if let match = find(child, id) { return match }
        }
        return nil
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private struct Fixture {
        let marketplace: HostMarketplace
        let directory: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.music-layout.\(UUID().uuidString)",
                supportDirectory: directory)
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            let defaults = UserDefaults(suiteName: identity.defaultsSuite)!
            let sessions = HostExtensionSessions(defaults: defaults) { _ in
                throw HostWorkerError.rejected
            }
            let client = ExtensionCatalogClient(
                url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                publicKey: Data(repeating: 0, count: 32),
                repository: MarketplaceConfiguration.repository,
                cache: directory.appendingPathComponent("catalog.json"),
                fetch: { _ in throw MarketplaceError.downloadFailed })
            let installer = ExtensionPackageInstaller(
                store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                verify: { _ in throw MarketplaceError.invalidSignature })
            marketplace = try HostMarketplace(
                identity: identity, entries: [], store: store, catalogClient: client,
                installer: installer, sessions: sessions)
        }
        func clean() {
            marketplace.surfaces.navigation.shutdown(); marketplace.surfaces.requests.shutdown()
            marketplace.surfaces.privacy.shutdown()
            UserDefaults(suiteName: marketplace.identity.identifier)?.removePersistentDomain(
                forName: marketplace.identity.identifier)
            UserDefaults(suiteName: marketplace.identity.defaultsSuite)?.removePersistentDomain(
                forName: marketplace.identity.defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
