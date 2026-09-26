import AppKit
import Foundation
import Testing
import WebKit

@testable import EdithHelper
@testable import EdithKit

@MainActor
@Suite(.serialized) struct NotchBrowserEvidenceTests {
    nonisolated private static let evidenceKey = "EDITH_NOTCH_BROWSER_EVIDENCE_DIR"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[evidenceKey] != nil))
    func theShelfBrowserRendersWithASyntheticChromeProfile() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        #expect(dataRoot.hasPrefix(runtime + "/"))
        guard dataRoot.hasPrefix(runtime + "/") else { return }
        let output = URL(
            fileURLWithPath: try #require(environment[Self.evidenceKey]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = TestWindowHost.application
        let defaults = SharedDefaults.store
        let quiet = [
            AppStorageKeys.Notch.alertsEnabled, AppStorageKeys.Notch.shelfHaptics,
            AppStorageKeys.Notch.shelfShowMusic,
        ]
        defaults.set(true, forKey: AppStorageKeys.Notch.shelfEnabled)
        defaults.set(true, forKey: AppStorageKeys.Notch.browserEnabled)
        for key in quiet { defaults.set(false, forKey: key) }
        defer { for key in quiet { defaults.removeObject(forKey: key) } }

        let server = try BrowserHTTPFixture(pages: SyntheticPages.pages)
        defer { server.stop() }
        let origin = try await server.origin()
        let host = origin.host() ?? "127.0.0.1"
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Default", name: "Mock Personal", email: "mock@example.com",
                cookies: [SyntheticChromeCookie(host: host, name: "session", value: "mock")],
                colorARGB: 0xFF1A_73E8),
            SyntheticChromeProfile(
                directory: "Profile 1", name: "Mock Work", email: "work@example.com",
                colorARGB: 0xFF34_A853),
        ])
        defer { chrome.remove() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = NotchBrowserStore(
            installation: Self.installation(chrome.userData),
            sessionFile: BrowserSessionFile(url: folder.appendingPathComponent("session.json")),
            defaults: defaults, keyProvider: { SyntheticChrome.key },
            dataStoreFactory: { _ in WKWebsiteDataStore.nonPersistent() })
        defer { store.shutdown() }
        let controller = NotchShelfController()
        defer { controller.shutdown() }
        store.applySize(CGSize(width: 900, height: 480))
        store.attach(store.profiles[0])
        try await eventually { store.profile != nil && store.syncState == .idle }
        let inbox = try #require(store.selectedTab)
        try await eventually { inbox.url != nil }
        inbox.webView.load(URLRequest(url: origin))
        store.newTab(origin.appendingPathComponent("docs"), select: false)
        store.newTab(origin.appendingPathComponent("calendar"), select: false)
        try await eventually { store.tabs.allSatisfy { !$0.isLoading && $0.title != "" } }
        controller.attachBrowser(store)
        let panel = try open(controller)
        try await settle()
        try await Self.capture(panel: panel, webView: inbox.webView)
            .write(to: output.appendingPathComponent("notch-browser.png"))
        controller.collapseNow()

        let locked = folder.appendingPathComponent("locked-chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let localState = locked.appendingPathComponent("Local State")
        try Data("{}".utf8).write(to: localState)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: localState.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: localState.path)
        }
        let blocked = NotchBrowserStore(
            installation: Self.installation(ChromeUserData(root: locked)),
            sessionFile: BrowserSessionFile(url: folder.appendingPathComponent("blocked.json")),
            defaults: defaults, keyProvider: { SyntheticChrome.key },
            dataStoreFactory: { _ in WKWebsiteDataStore.nonPersistent() })
        defer { blocked.shutdown() }
        guard case .unreadable = blocked.readiness else {
            Issue.record("expected unreadable Chrome data, got \(blocked.readiness)")
            return
        }
        blocked.applySize(CGSize(width: 720, height: 360))
        controller.attachBrowser(blocked)
        let blockedPanel = try open(controller)
        try await settle()
        try await Self.capture(panel: blockedPanel, webView: nil)
            .write(to: output.appendingPathComponent("notch-browser-unreadable.png"))
        controller.collapseNow()
    }

    private func settle() async throws {
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(250))
            await Task.yield()
        }
    }

    private static func installation(_ userData: ChromeUserData) -> ChromeInstallation {
        ChromeInstallation(
            applicationURL: { URL(fileURLWithPath: "/Applications/Google Chrome.app") },
            defaultBrowser: { ("com.google.Chrome", "Google Chrome") },
            userData: userData)
    }

    private func open(_ controller: NotchShelfController) throws -> NSPanel {
        let panel = try #require(NSApp.windows.compactMap { $0 as? NotchPanel }.first)
        let screen = try #require(panel.screen ?? NSScreen.main)
        let id = try #require(
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID)
        controller.selectTab(.browser)
        controller.expand(on: id)
        return panel
    }

    private static func capture(panel: NSPanel, webView: WKWebView?) async throws -> Data {
        let content = try #require(panel.contentView)
        let shape = try #require((content as? ShelfDropCatcherView)?.interactiveShapeSize)
        var page: NSImage?
        if let webView {
            for _ in 0..<10 {
                page = try? await webView.takeSnapshot(configuration: nil)
                if page != nil { break }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        let scale = 2
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width) * scale,
                pixelsHigh: Int(content.bounds.height) * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        representation.size = content.bounds.size
        content.cacheDisplay(in: content.bounds, to: representation)
        if let page, let container = find(BrowserWebContainerView.self, in: content) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
            let target = content.convert(container.bounds, from: container)
            NSBezierPath(
                roundedRect: target, xRadius: BrowserWebContainerView.cornerRadius,
                yRadius: BrowserWebContainerView.cornerRadius
            ).addClip()
            page.draw(in: target)
            NSGraphicsContext.restoreGraphicsState()
        }
        let crop = CGRect(
            x: (content.bounds.width - shape.width) / 2 * CGFloat(scale), y: 0,
            width: shape.width * CGFloat(scale),
            height: (shape.height + NotchGeometry.panelPadding.height) * CGFloat(scale))
        let cropped = try #require(representation.cgImage?.cropping(to: crop))
        return try #require(
            NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    private func eventually(
        _ timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Condition did not become true in time")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private enum SyntheticPages {
    static let pages: [String: String] = [
        "/": inbox, "/docs": docs, "/calendar": calendar, "/favicon.ico": "",
    ]

    private static let style = """
        <style>
        body{margin:0;font:14px -apple-system,Helvetica;background:#fff;color:#202124}
        header{display:flex;align-items:center;gap:14px;padding:12px 20px;border-bottom:1px solid #e0e0e0}
        header b{font-size:18px}header input{flex:1;max-width:560px;border:0;background:#f1f3f4;border-radius:8px;padding:9px 14px;font-size:14px}
        .avatar{margin-left:auto;width:32px;height:32px;border-radius:50%;background:#1a73e8;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:600}
        main{display:flex}nav{width:200px;padding:16px 10px}nav div{padding:8px 14px;border-radius:18px;margin-bottom:2px}
        nav .on{background:#d3e3fd;font-weight:600}
        section{flex:1}.row{display:flex;gap:16px;padding:11px 20px;border-bottom:1px solid #f1f3f4}
        .row .from{width:180px;font-weight:600}.row .when{margin-left:auto;color:#5f6368}
        .row.unread{background:#f2f6fc}h1{margin:0 0 6px;font-size:22px}p{line-height:1.6;max-width:720px}
        .card{border:1px solid #e0e0e0;border-radius:10px;padding:16px;margin:12px 20px}
        table{border-collapse:collapse;width:100%}td{border:1px solid #e0e0e0;height:64px;vertical-align:top;padding:6px;font-size:12px}
        .ev{background:#d3e3fd;border-radius:4px;padding:3px 6px;margin-top:4px}
        </style>
        """

    private static func shell(title: String, body: String) -> String {
        """
        <html><head><title>\(title)</title>\(style)</head><body>
        <header><b>\(title)</b><input placeholder="Search"><div class="avatar">MP</div></header>
        <main>\(body)</main></body></html>
        """
    }

    static let inbox = shell(
        title: "Mock Mail",
        body: """
            <nav><div class="on">Inbox 4</div><div>Starred</div><div>Sent</div><div>Drafts</div><div>Archive</div></nav>
            <section>
            <div class="row unread"><span class="from">Mock Team</span><span>Weekly sync notes and next steps</span><span class="when">9:41 AM</span></div>
            <div class="row unread"><span class="from">Design Review</span><span>Shelf browser mockups are ready</span><span class="when">9:12 AM</span></div>
            <div class="row"><span class="from">Build Bot</span><span>CI passed on main</span><span class="when">8:55 AM</span></div>
            <div class="row unread"><span class="from">Mock Calendar</span><span>Reminder: 1:1 at 2:00 PM</span><span class="when">8:30 AM</span></div>
            <div class="row"><span class="from">Newsletter</span><span>This week in mock news</span><span class="when">Yesterday</span></div>
            <div class="row unread"><span class="from">Sam Mock</span><span>Lunch on Thursday?</span><span class="when">Yesterday</span></div>
            <div class="row"><span class="from">Receipts</span><span>Your mock order has shipped</span><span class="when">Sep 23</span></div>
            </section>
            """)

    static let docs = shell(
        title: "Mock Docs",
        body: """
            <section><div class="card"><h1>Roadmap Q4</h1>
            <p>This is a mock document served from a local fixture. It contains no real data.</p>
            </div></section>
            """)

    static let calendar = shell(
        title: "Mock Calendar",
        body: """
            <section><div class="card"><h1>September 2026</h1><table>
            <tr><td>Mon 21</td><td>Tue 22</td><td>Wed 23<div class="ev">Design review</div></td><td>Thu 24</td><td>Fri 25</td></tr>
            </table></div></section>
            """)
}
