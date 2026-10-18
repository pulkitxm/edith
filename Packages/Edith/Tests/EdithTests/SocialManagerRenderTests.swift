import AppKit
import EdithKit
import SwiftUI
import Testing
import WebKit

@testable import Edith

@MainActor @Suite(.serialized)
struct SocialManagerRenderTests {
    @Test func syntheticAccountsAndMixedPlatformPanesRenderAcrossWindowLayouts() async throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let studio = try model.saveProfile(
            id: model.catalog.profiles[0].id, name: "Studio", badge: "ST",
            email: "studio@example.test")
        for (index, account) in model.catalog.accounts.enumerated() {
            let source = fixture.folder.appendingPathComponent("mock-picture-\(index).png")
            let image = NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
                [NSColor.systemTeal, .systemOrange, .systemIndigo][index % 3].setFill()
                rect.fill()
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: CGRect(x: 42, y: 62, width: 36, height: 36)).fill()
                NSBezierPath(ovalIn: CGRect(x: 24, y: 4, width: 72, height: 52)).fill()
                return true
            }
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: source)
            try model.importAvatar(account, from: source)
        }
        model.profileID = nil
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        for scheme in [ColorScheme.light, .dark] {
            try await capture(model, width: 1180, scheme: scheme, name: "profiles-\(scheme)")
        }
        model.profileID = model.catalog.profiles[0].id
        for scale in [1.0, 1.4] {
            UIScale.apply(scale)
            for width in [CGFloat(1180), CGFloat(620)] {
                for scheme in [ColorScheme.light, .dark] {
                    try await capture(
                        model, width: width, scheme: scheme,
                        name: "accounts-\(Int(width))-\(scheme)-\(scale)")
                }
            }
        }
        UIScale.apply(1)
        for account in [
            model.catalog.accounts[0], model.catalog.accounts[1], model.catalog.accounts[2],
            model.catalog.accounts[4],
        ] {
            model.open(account, beside: model.currentTab != nil)
            let page = try #require(model.sessions[account.id]?.selectedPage)
            page.webView.loadHTMLString(
                Self.mockWebsite(account.name), baseURL: URL(string: "https://social.example.test"))
        }
        model.grid()
        try await capture(model, width: 1440, scheme: .dark, name: "mixed-platform-grid")
        try await capture(model, width: 1440, scheme: .light, name: "mixed-platform-grid-light")
        model.arrange(.vertical)
        try await capture(model, width: 620, scheme: .light, name: "compact-panes")
        model.toggleZoom(model.catalog.accounts[0].id.uuidString)
        try await capture(model, width: 1180, scheme: .dark, name: "maximized-account")
        let social = model.catalog.accounts[0]
        model.openInNewTab(social)
        model.openEmail(studio, beside: true)
        let email = try #require(model.sessions[studio.id]?.selectedPage)
        email.webView.loadHTMLString(
            Self.mockInbox, baseURL: URL(string: "https://mail.example.test"))
        try await capture(model, width: 1440, scheme: .light, name: "account-and-email")
    }

    private func capture(
        _ model: SocialManagerModel, width: CGFloat, scheme: ColorScheme, name: String
    ) async throws {
        let host = NSHostingView(
            rootView: SocialManagerPage(model: model)
                .environment(\.compactLayout, width < UIScale.pt(640))
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.loadingAnimationsEnabled, false)
                .environment(\.colorScheme, scheme))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: width, height: 940)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.bounds.width - width) < 2)
        #expect(abs(host.bounds.height - 940) < 2)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        var snapshots: [(NSImage, CGRect)] = []
        if !model.showingAccounts, let tab = model.currentTab {
            for key in tab.layout.panes where tab.zoomed == nil || tab.zoomed == key {
                let id = try #require(UUID(uuidString: key))
                let page = try #require(model.sessions[id]?.selectedPage)
                for _ in 0..<100 where page.isLoading || page.title != "Mock social" {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(!page.isLoading && page.title == "Mock social")
                let webView = page.webView
                #expect(webView.window === window)
                #expect(webView.bounds.width > 120)
                #expect(webView.bounds.height > 40)
                let bounds = host.convert(webView.bounds, from: webView)
                #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(bounds))
                let image = try await webView.takeSnapshot(configuration: nil)
                snapshots.append((image, bounds))
            }
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if !snapshots.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            for (image, bounds) in snapshots {
                let destination = CGRect(
                    x: bounds.minX, y: host.bounds.height - bounds.maxY, width: bounds.width,
                    height: bounds.height)
                image.draw(in: destination)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let directory = ProcessInfo.processInfo.environment["EDITH_SOCIAL_MANAGER_EVIDENCE_DIR"]
        {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
    }

    private static func mockWebsite(_ name: String) -> String {
        """
        <html><head><title>Mock social</title><style>
        *{box-sizing:border-box}body{margin:0;font:14px -apple-system;background:#fafafa;color:#19232f}
        header{padding:18px 24px;border-bottom:1px solid #e3e8ef;background:white;display:flex;justify-content:space-between}
        main{max-width:540px;margin:24px auto;padding:0 20px}.profile{display:flex;align-items:center;gap:14px}
        .avatar{width:52px;height:52px;background:#dcece8;border-radius:50%;display:grid;place-items:center;font-weight:700}
        h1{font-size:19px;margin:0 0 4px}small{color:#697686}.post{margin-top:22px;border:1px solid #e3e8ef;border-radius:12px;overflow:hidden;background:white}
        .art{height:140px;background:linear-gradient(135deg,#d7ebe4,#f1e4cb);display:grid;place-items:center;color:#315e51;font-size:24px;font-weight:600}
        p{padding:0 16px;line-height:1.6}button{border:1px solid #d4ddd8;border-radius:7px;background:white;padding:8px 14px;color:#315e51}
        </style></head><body><header><b>Social preview</b><span>Home · Messages</span></header>
        <main><div class="profile"><div class="avatar">\(name.prefix(1))</div><div><h1>\(name)</h1><small>Synthetic demo account</small></div></div>
        <div class="post"><div class="art">A little room to create.</div><p><b>\(name)</b><br>A fresh collection of ideas for the week. Saved in this account's own workspace.</p><p><button>View post</button></p></div></main></body></html>
        """
    }

    private static let mockInbox = """
        <html><head><title>Mock social</title><style>
        body{margin:0;background:#f6f8fc;color:#202124;font:14px -apple-system}
        header{padding:24px;background:white;border-bottom:1px solid #dde3eb}
        main{padding:24px}h1{font-size:22px}article{padding:18px;background:white;border-bottom:1px solid #eef1f5}
        small{color:#637083}b{display:block;margin-bottom:8px}
        </style></head><body><header><b>Mail preview</b><small>studio@example.test</small></header>
        <main><h1>Inbox</h1><article><b>Your sign-in code</b>Use 123456 to finish signing in to your demo account.</article>
        <article><b>Campaign review</b>The mock launch assets are ready for review.</article>
        <article><b>Weekly digest</b>Three new ideas for your next post.</article></main></body></html>
        """
}
