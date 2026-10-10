import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite struct MusicAuxiliarySceneTests {
        @Test func fixedRoutesUseOriginalPageAndAuxiliaryViews() throws {
            for route in MusicSceneRoute.allCases {
                let input: NSDictionary = ["location": route.rawValue, "section": "music"]
                #expect(MusicSceneRoute(input) == route)
                let state = ExtensionPresentationState(
                    compact: true, visible: false, availableWidth: 540, intrinsic: route != .page)
                let controller = try #require(
                    state.withContext { MusicAuxiliaryScenes.controller(input) })
                switch route {
                case .page:
                    #expect(controller is NSHostingController<ExtensionPageHost<MusicPage>>)
                case .footer:
                    #expect(controller is NSHostingController<ExtensionPageHost<MusicFooterScene>>)
                case .sidebar:
                    #expect(controller is NSHostingController<ExtensionPageHost<MusicSidebarScene>>)
                case .detail:
                    #expect(
                        controller is NSHostingController<ExtensionPageHost<MusicDetailOverlay>>)
                }
            }
            for input: NSDictionary in [
                [:], ["location": "main"], ["location": "settings", "section": "music"],
                ["location": "main", "section": "downloads"],
                ["location": "music.footer", "section": "foreign"],
                ["location": "music.footer", "section": 1],
            ] {
                #expect(MusicSceneRoute(input) == nil)
                #expect(MusicAuxiliaryScenes.controller(input) == nil)
            }
            #expect(ExtensionPresentationState.current == nil)
        }

        @Test func nativeSidebarExpandAndFooterCollapseShareOriginalPreference() async throws {
            let restore = accessibility()
            defer { restore() }
            let defaults = SharedDefaults.store
            defaults.set(false, forKey: AppStorageKeys.Music.barAutoHide)
            defaults.set(true, forKey: AppStorageKeys.Music.barCollapsed)
            defer {
                defaults.removeObject(forKey: AppStorageKeys.Music.barAutoHide)
                defaults.removeObject(forKey: AppStorageKeys.Music.barCollapsed)
            }
            let sidebar = try #require(
                MusicAuxiliaryScenes.controller([
                    "location": "music.sidebar", "section": "music",
                ]))
            let footer = try #require(
                MusicAuxiliaryScenes.controller([
                    "location": "music.footer", "section": "music",
                ]))
            for (controller, label, collapsed) in [
                (sidebar, "Show the player bar", false), (footer, "Collapse the player bar", true),
            ] {
                let host = controller.view
                host.frame = CGRect(x: 0, y: 0, width: 400, height: 150)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentViewController = controller; window.orderBack(nil)
                await settle(window)
                let button = try #require(find(host, label: label))
                #expect((button as AnyObject).accessibilityPerformPress?() == true)
                await settle(window)
                #expect(defaults.bool(forKey: AppStorageKeys.Music.barCollapsed) == collapsed)
                #expect(!TestWindowHost.isExposedOnDesktop(window))
                window.orderOut(nil); window.contentViewController = nil
            }
        }

        @Test func autoHideRemovesIdleChromeAndLiveSceneLayoutCanChange() async throws {
            let restore = accessibility()
            defer { restore() }
            let previousScale = UIScale.current
            defer { UIScale.apply(previousScale) }
            let defaults = SharedDefaults.store
            defaults.set(false, forKey: AppStorageKeys.Music.barAutoHide)
            defaults.set(false, forKey: AppStorageKeys.Music.barCollapsed)
            defer {
                defaults.removeObject(forKey: AppStorageKeys.Music.barAutoHide)
                defaults.removeObject(forKey: AppStorageKeys.Music.barCollapsed)
            }
            #expect(MusicAccounts.shared.selected == .local)
            #expect(MusicAccounts.shared.playerTitle == nil)
            for (width, zoom, scheme) in [(540.0, 1.0, ColorScheme.light), (960.0, 1.5, .dark)] {
                UIScale.apply(zoom)
                let state = ExtensionPresentationState(
                    compact: width < 720, visible: false, availableWidth: width, intrinsic: true)
                let controller = try #require(
                    state.withContext {
                        MusicAuxiliaryScenes.controller([
                            "location": "music.footer", "section": "music",
                        ])
                    })
                let host = controller.view
                host.frame = CGRect(x: 0, y: 0, width: width, height: 150)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentViewController = controller
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.orderBack(nil)
                await settle(window)
                #expect(find(host, label: "Collapse the player bar") != nil)
                state.compact.toggle(); state.visible = true; state.availableWidth = width / 2
                host.frame.size.width = width / 2
                await settle(window)
                #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                defaults.set(true, forKey: AppStorageKeys.Music.barAutoHide)
                await settle(window)
                #expect(find(host, label: "Collapse the player bar") == nil)
                defaults.set(false, forKey: AppStorageKeys.Music.barAutoHide)
                await settle(window)
                #expect(find(host, label: "Collapse the player bar") != nil)
                #expect(!TestWindowHost.isExposedOnDesktop(window))
                window.orderOut(nil); window.contentViewController = nil
            }
        }

        private func settle(_ window: NSWindow) async {
            for _ in 0..<8 {
                window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(40))
            }
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

        private func accessibility() -> () -> Void {
            _ = TestWindowHost.application
            let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
                NSAccessibility.Attribute(rawValue: $0)
            }
            let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
            for attribute in attributes {
                NSApp.accessibilitySetValue(true, forAttribute: attribute)
            }
            return {
                for (attribute, value) in zip(attributes, previous) {
                    NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
                }
            }
        }
    }
}
