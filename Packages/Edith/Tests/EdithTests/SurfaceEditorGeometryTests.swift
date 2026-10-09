import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct SurfaceEditorGeometryTests {
    @Test func selectingFirstWidgetKeepsCanvasGeometryStable() async throws {
        let restore = enableAccessibility()
        defer { restore() }
        let shared = SharedDefaults.store
        let oldTarget = shared.string(forKey: AppStorageKeys.Surfaces.editorTarget)
        let oldSelection = shared.string(forKey: AppStorageKeys.Surfaces.editorWidget)
        shared.set("home", forKey: AppStorageKeys.Surfaces.editorTarget)
        shared.set("", forKey: AppStorageKeys.Surfaces.editorWidget)
        defer {
            shared.set(oldTarget, forKey: AppStorageKeys.Surfaces.editorTarget)
            shared.set(oldSelection, forKey: AppStorageKeys.Surfaces.editorWidget)
        }
        let host = NSHostingView(
            rootView: SurfaceEditorPane()
                .environment(\.compactLayout, false)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        let first = try #require(findFrame(host, label: "Move World clocks"))
        #expect(findFrame(host, label: "Lock layout") == nil)
        shared.set(SurfaceWidget.clocks.id, forKey: AppStorageKeys.Surfaces.editorWidget)
        await settle(window, host: host)
        let selected = try #require(findFrame(host, label: "Move World clocks"))
        #expect(findFrame(host, label: "Lock layout") != nil)
        #expect(abs(first.minX - selected.minX) < 1)
        #expect(abs(first.width - selected.width) < 1)
        shared.set("", forKey: AppStorageKeys.Surfaces.editorWidget)
        await settle(window, host: host)
        let cleared = try #require(findFrame(host, label: "Move World clocks"))
        #expect(findFrame(host, label: "Lock layout") == nil)
        #expect(abs(first.minX - cleared.minX) < 1)
        #expect(abs(first.width - cleared.width) < 1)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    private func findFrame(_ node: NSObject, label: String, depth: Int = 0) -> CGRect? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label {
            return (node as AnyObject).accessibilityFrame?()
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = findFrame(child, label: label, depth: depth + 1) { return result }
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
        for _ in 0..<5 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

}
