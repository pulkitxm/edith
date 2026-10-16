import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import PresenterExtension

@MainActor @Suite(.serialized) struct PresenterSidebarSceneTests {
    @Test func fixedPrivacyRouteCreatesOnlyOriginalCompactView() throws {
        let controller = try #require(
            PresenterSidebarScene.controller([
                "location": "sidebar.utility", "section": "privacy",
            ]))
        #expect(controller is NSHostingController<ExtensionPageHost<PresenterSidebarScene>>)
        for input: NSDictionary in [
            [:], ["location": "sidebar.utility"], ["location": "main", "section": "privacy"],
            ["location": "sidebar.utility", "section": "foreign"],
        ] {
            #expect(PresenterSidebarScene.controller(input) == nil)
        }
    }

    @Test func actualManualAndPrivacyButtonsPersistAcrossReconstructedScenes() async throws {
        let restore = accessibility()
        defer { restore() }
        let defaults = SharedDefaults.store
        let keys =
            [AppStorageKeys.Presenter.enabled, AppStorageKeys.Presenter.mode]
            + PresenterPrivacy.allCases.map(\.storageKey)
        let previous = keys.map { defaults.object(forKey: $0) }
        let previousScale = UIScale.current
        defer {
            for (key, value) in zip(keys, previous) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            UIScale.apply(previousScale)
        }
        defaults.set(true, forKey: AppStorageKeys.Presenter.enabled)
        defaults.set(false, forKey: AppStorageKeys.Presenter.mode)
        defaults.set(true, forKey: PresenterPrivacy.music.storageKey)
        defaults.set(false, forKey: PresenterPrivacy.usage.storageKey)
        for (zoom, scheme) in [(1.0, NSAppearance.Name.aqua), (1.5, .darkAqua)] {
            UIScale.apply(zoom)
            let state = ExtensionPresentationState(
                compact: true, visible: false, availableWidth: UIScale.pt(250), intrinsic: true)
            let controller = try #require(
                state.withContext {
                    PresenterSidebarScene.controller([
                        "location": "sidebar.utility", "section": "privacy",
                    ])
                })
            let window = PresenterTestWindowHost.window(
                contentRect: CGRect(
                    x: 0, y: 0, width: UIScale.pt(250), height: UIScale.pt(480)))
            window.contentViewController = controller
            window.appearance = NSAppearance(named: scheme); window.orderBack(nil)
            await settle(window)
            let manual = try #require(find(controller.view, label: "Manual presenter mode"))
            #expect((manual as AnyObject).accessibilityPerformPress?() == true)
            await settle(window)
            #expect(defaults.bool(forKey: AppStorageKeys.Presenter.mode))
            #expect((manual as AnyObject).accessibilityPerformPress?() == true)
            await settle(window)
            #expect(!defaults.bool(forKey: AppStorageKeys.Presenter.mode))
            let music = try #require(find(controller.view, label: PresenterPrivacy.music.title))
            #expect((music as AnyObject).accessibilityPerformPress?() == true)
            await settle(window)
            #expect(!defaults.bool(forKey: PresenterPrivacy.music.storageKey))
            let usage = try #require(find(controller.view, label: PresenterPrivacy.usage.title))
            #expect((usage as AnyObject).accessibilityPerformPress?() == true)
            await settle(window)
            #expect(defaults.bool(forKey: PresenterPrivacy.usage.storageKey))
            state.visible = true; state.compact = false
            await settle(window)
            #expect(controller.view.fittingSize.height.isFinite)
            #expect(!PresenterTestWindowHost.isExposedOnDesktop(window))
            window.orderOut(nil); window.contentViewController = nil
            let restored = try #require(
                PresenterSidebarScene.controller([
                    "location": "sidebar.utility", "section": "privacy",
                ]))
            #expect(restored is NSHostingController<ExtensionPageHost<PresenterSidebarScene>>)
            #expect(!PresenterPrivacy.music.hides(active: true, defaults: defaults))
            #expect(PresenterPrivacy.usage.hides(active: true, defaults: defaults))
            defaults.set(false, forKey: AppStorageKeys.Presenter.enabled)
            #expect(!PresenterRuntimeOperationExecution.perform(.start).active)
            #expect(!defaults.bool(forKey: AppStorageKeys.Presenter.mode))
            #expect(!defaults.bool(forKey: PresenterPrivacy.music.storageKey))
            defaults.set(true, forKey: AppStorageKeys.Presenter.enabled)
            defaults.set(true, forKey: PresenterPrivacy.music.storageKey)
            defaults.set(false, forKey: PresenterPrivacy.usage.storageKey)
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
        _ = PresenterTestWindowHost.application
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
}
