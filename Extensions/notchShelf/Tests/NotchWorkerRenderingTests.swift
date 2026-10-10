import AppKit
import QuartzCore
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchWorkerRenderingTests {
    @Test func realNotchHomeAndFilesRenderWithoutExposureOrProviderRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.controller.layouts.update(.notch) {
            $0.tiles = [SurfaceTile(.clocks)]
            $0.notchAutoWidth = false
            $0.notchWidth = 580
            $0.notchLeadingGlance = .files
            $0.notchTrailingGlance = .clock
        }
        let pasteboard = NSPasteboard(name: .init("notch-render-mock-" + UUID().uuidString))
        pasteboard.setString("synthetic project note", forType: .string)
        #expect(fixture.controller.handleDrop(from: pasteboard))
        fixture.controller.expand(on: 0, preferredTab: .home)
        for tab in [SurfaceNotchTab.home, .files] {
            fixture.controller.selectTab(tab)
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(
                    rootView: NotchShelfContentView(controller: fixture.controller)
                        .preferredColorScheme(scheme)
                        .environment(\.automaticViewActionsEnabled, false)
                        .transaction { $0.animation = nil })
                host.frame = CGRect(x: 0, y: 0, width: 660, height: 460)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentView = host; window.orderBack(nil)
                await settle(window, host)
                #expect(host.bounds.size == CGSize(width: 660, height: 460))
                #expect(!TestWindowHost.isExposedOnDesktop(window))
                #expect(fixture.controller.requests.pendingCount == 0)
                try capture(
                    host, name: "notch-" + tab.rawValue + "-" + (scheme == .dark ? "dark" : "light")
                )
                window.orderOut(nil)
            }
        }
    }

    @Test func settingsRenderAtCompactRegularAndIncreasedZoom() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        for (name, width, zoom) in [
            ("compact", 540.0, 1.0), ("regular", 960.0, 1.0), ("zoomed", 960.0, 1.5),
        ] {
            UIScale.apply(zoom)
            let host = NSHostingView(
                rootView: NotchSettingsPage(controller: fixture.controller)
                    .environment(\.compactLayout, width < 720)
                    .environment(\.automaticViewActionsEnabled, false)
                    .preferredColorScheme(.dark)
                    .transaction { $0.animation = nil })
            host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host; window.orderBack(nil)
            await settle(window, host)
            #expect(abs(host.bounds.width - width) < 1)
            #expect(!TestWindowHost.isExposedOnDesktop(window))
            #expect(fixture.controller.requests.pendingCount == 0)
            try capture(host, name: "notch-settings-" + name)
            window.orderOut(nil)
        }
    }

    private func settle(_ window: NSWindow, _ host: NSView) async {
        for _ in 0..<16 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.displayIfNeeded()
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_NOTCH"] else {
            return
        }
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let data = try #require(representation.representation(using: .png, properties: [:]))
        #expect(data.count > 2_000)
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }

    @MainActor private struct Fixture {
        let id = "notch-render-tests-" + UUID().uuidString
        let root: URL
        let controller: NotchShelfController

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
            let defaults = try #require(UserDefaults(suiteName: id))
            defaults.set(false, forKey: AppStorageKeys.Notch.alertsEnabled)
            defaults.set(false, forKey: AppStorageKeys.Notch.shelfHaptics)
            let state = ExtensionSharedState(root: root, namespace: id, owner: "host")
            try state.publish([
                "surface.activeIDs": "[\"notchShelf\"]",
                "surface.activeVersions": "{\"notchShelf\":\"1\"}",
            ])
            controller = NotchShelfController(
                context: .init(defaults: defaults, sharedState: state), startsServices: false,
                root: root.appendingPathComponent("Shelf"))
        }

        func clean() {
            controller.shutdown()
            UserDefaults.standard.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
