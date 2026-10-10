import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrSettingsTests {
    @Test func settingsFacadeUsesFixedOperationsAndDoesNotApplyStaleReplies() async throws {
        var pending: CheckedContinuation<Data, Error>?
        let model = HerdrSettingsModel { operation, payload in
            #expect(operation == "herdr.settings.read" && payload == Data("{}".utf8))
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let read = Task { await model.read() }
        while pending == nil { await Task.yield() }
        model.shutdown()
        pending?.resume(returning: try AgentPayload.encode(HerdrAttentionSettings(blocked: false)))
        await read.value
        #expect(model.settings.blocked && !model.loading && model.error == nil)
    }

    @Test func invalidBoundsAreRejectedAndFailedSaveRetainsPreviouslyLoadedSettings() async throws {
        var calls = 0
        let model = HerdrSettingsModel { operation, payload in
            calls += 1
            if calls == 1 {
                #expect(operation == "herdr.settings.read")
                return try AgentPayload.encode(
                    HerdrAttentionSettings(stuck: true, stuckMinutes: 15))
            }
            #expect(operation == "herdr.settings.save")
            let saved = try AgentPayload.decode(HerdrAttentionSettings.self, from: payload)
            #expect(saved.stuckMinutes == 120)
            throw ExtensionPeerError.unavailable
        }
        await model.read()
        model.update { $0.stuckMinutes = 300 }
        while calls < 2 || model.loading { await Task.yield() }
        #expect(model.settings.stuckMinutes == 15 && model.error != nil)
        let invalid = HerdrSettingsModel { _, _ in
            try AgentPayload.encode(HerdrAttentionSettings(stuckMinutes: 121))
        }
        await invalid.read()
        #expect(invalid.error != nil && invalid.settings.stuckMinutes == 10)
        model.shutdown()
        invalid.shutdown()
    }

    @Test func engineSettingsRejectInjectedFieldsTypesBoundsAndDisabledOwner() async throws {
        let suite = "herdr.settings.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { HerdrWorkOwnership.enable() }
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }),
            defaults: defaults, automaticActions: false)
        let initial = try AgentPayload.decode(
            HerdrAttentionSettings.self,
            from: await worker.execute("herdr.settings.read", payload: Data("{}".utf8)))
        #expect(initial.blocked && initial.finished && initial.errors && initial.stuckMinutes == 10)
        let settings = HerdrAttentionSettings(
            blocked: false, finished: false, errors: false,
            stuck: true, openDiff: true, stuckMinutes: 20, monitoring: true)
        let saved = try AgentPayload.decode(
            HerdrAttentionSettings.self,
            from: await worker.execute(
                "herdr.settings.save", payload: AgentPayload.encode(settings)))
        #expect(saved == settings && worker.activity.stuckMinutes == 20)
        let object = try #require(
            try JSONSerialization.jsonObject(with: AgentPayload.encode(settings)) as? [String: Any])
        for (key, value) in [
            ("path", "/tmp/mock" as Any), ("stuckMinutes", 1 as Any), ("stuckMinutes", true as Any),
            ("blocked", 1 as Any),
        ] {
            var invalid = object
            invalid[key] = value
            await #expect(throws: ExtensionPeerError.self) {
                try await worker.execute(
                    "herdr.settings.save", payload: JSONSerialization.data(withJSONObject: invalid))
            }
        }
        #expect(HerdrAttentionSettings(defaults: defaults) == settings)
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("herdr.settings.read", payload: Data("{}".utf8))
        }
    }

    @Test func notificationSettingsRenderAtCompactRegularWidthsZoomAndColorSchemes() async throws {
        _ = TestWindowHost.application
        let model = HerdrSettingsModel { _, _ in
            try AgentPayload.encode(HerdrAttentionSettings(stuck: true))
        }
        await model.read()
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let prior = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        let previousZoom = UIScale.current
        defer {
            UIScale.apply(previousZoom)
            for (attribute, value) in zip(attributes, prior) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
            model.shutdown()
        }
        for zoom in [1.0, 1.5] {
            UIScale.apply(zoom)
            for width in [520.0, 1100.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: HerdrSettingsPage(model: model)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.colorScheme, scheme)
                            .environment(\.compactLayout, width < 600))
                    host.frame = .init(x: 0, y: 0, width: width, height: 1000)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderBack(nil)
                    defer { window.orderOut(nil); window.contentView = nil; window.close() }
                    for _ in 0..<4 {
                        window.layoutIfNeeded()
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    for label in [
                        "Needs approval or an answer", "Finishes its work", "Hits an error",
                        "Looks stuck", "Open the diff when an agent finishes",
                    ] {
                        let control = try #require(
                            find(host, label: label),
                            "Missing \(label) at width \(width), zoom \(zoom), scheme \(scheme)")
                        let frame = (control as AnyObject).accessibilityFrame?() ?? .zero
                        #expect(frame.width > 0 && frame.height > 0)
                        #expect(
                            frame.minX >= window.frame.minX && frame.maxX <= window.frame.maxX,
                            "\(label) at width \(width), zoom \(zoom), scheme \(scheme), frame \(frame), window \(window.frame)"
                        )
                    }
                    #expect(!TestWindowHost.isExposedOnDesktop(window))
                }
            }
        }
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = find(child, label: label, depth: depth + 1) { return result }
        }
        return nil
    }
}
