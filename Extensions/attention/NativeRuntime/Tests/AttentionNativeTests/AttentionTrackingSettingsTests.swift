import AppKit
import EdithExtensionSupport_attention_native
import EdithExtensionUI_attention_native
import SwiftUI
import Testing
@testable import AttentionNative

@Suite(.serialized) @MainActor struct AttentionTrackingSettingsTests {
    @Test func originalTrackingEditsRoundTripWithoutCollectionAndSurviveDisable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "synthetic-attention-detail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AttentionDatabase(url: root.appendingPathComponent("history.sqlite"))
        let repository = AttentionRepository(
            root: root, eventSink: AttentionEventStore(store: database))
        let service = AttentionBackgroundService(
            store: database, root: root, cloudDirectory: root.appendingPathComponent("cloud"),
            cloudAvailable: { false }, collectsSystemActivity: false)
        var original = AttentionSettings()
        original.profileNote = "Synthetic preserved setting"
        original.agentTrackingEnabled = false
        original.trackingEnabled = false
        original.browserTrackingEnabled = false
        try repository.saveSettings(original)
        var operations: [String] = []
        let client = AttentionUIClient(send: { operation, payload in
            operations.append(operation)
            return try await AttentionCommands.execute(
                operation, payload: payload, service: service)
        })
        let model = AttentionTrackingSettingsModel(client: client)
        await model.load()
        #expect(
            model.loaded && !model.settings.trackingEnabled
                && !model.settings.browserTrackingEnabled)
        model.settings.trackingEnabled = true
        model.settings.browserTrackingEnabled = true
        model.save()
        for _ in 0..<100 where model.message == nil { try await Task.sleep(for: .milliseconds(10)) }
        let saved = repository.loadSettings()
        #expect(saved.isEnabled && saved.trackingEnabled && saved.browserTrackingEnabled)
        #expect(saved.profileNote == original.profileNote && !saved.agentTrackingEnabled)
        #expect(model.message == "Settings saved" && model.errorMessage == nil)
        model.settings.trackingEnabled = false
        model.settings.browserTrackingEnabled = false
        model.message = nil
        model.save()
        for _ in 0..<100 where model.message == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!repository.loadSettings().isEnabled)
        #expect(
            operations == [
                "attention.settings.get", "attention.settings.set", "attention.settings.set",
            ])
        model.stop()
        await service.stop()
        let reopened = AttentionRepository(
            root: root, eventSink: AttentionEventStore(store: database))
        #expect(reopened.loadSettings().profileNote == original.profileNote)
        #expect(
            !reopened.loadSettings().trackingEnabled
                && !reopened.loadSettings().browserTrackingEnabled)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.invoke("attention.settings.get")
        }
        try database.close()
    }

    @Test func closingRejectsLateSettingsAndCancelsQueuedSaves() async throws {
        var held: CheckedContinuation<Data, Error>?
        let loadingClient = AttentionUIClient(send: { _, _ in
            try await withCheckedThrowingContinuation { held = $0 }
        })
        let loadingModel = AttentionTrackingSettingsModel(client: loadingClient)
        let loading = Task { await loadingModel.load() }
        while held == nil { await Task.yield() }
        loadingModel.stop()
        var late = AttentionSettings(); late.profileNote = "Late mock settings"
        held?.resume(returning: try AttentionPayload.encode(late))
        await loading.value
        #expect(!loadingModel.loaded && loadingModel.settings.profileNote.isEmpty)
        var save: CheckedContinuation<Data, Error>?
        var operations: [String] = []
        let client = AttentionUIClient(send: { operation, _ in
            operations.append(operation)
            if operation == "attention.settings.get" {
                return try AttentionPayload.encode(AttentionSettings())
            }
            return try await withCheckedThrowingContinuation { save = $0 }
        })
        let model = AttentionTrackingSettingsModel(client: client)
        await model.load()
        model.settings.trackingEnabled = true
        model.save()
        while save == nil { await Task.yield() }
        model.settings.trackingEnabled = false
        model.save()
        model.stop()
        save?.resume(returning: try AttentionPayload.encode(late))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.message == nil && !model.settings.trackingEnabled)
        #expect(operations == ["attention.settings.get", "attention.settings.set"])
    }

    @Test func factoryExportsOriginalDetailAndScopesCurrentClient() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = AttentionExtensionController(bundle: .main)
        let bridge = TrackingDetailBridge()
        let engine = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        var context: [String: Any] = [
            "operation": "view", "extensionID": "attention", "uiOnly": false,
            "presentationID": engine.presentationID.uuidString, "location": "settings",
            "section": "extension",
        ]
        #expect(controller.configurePresentation(context as NSDictionary, engine: engine))
        #expect(controller.trackingSettings != nil)
        let view = try #require(controller.execute(context as NSDictionary) as? NSViewController)
        #expect(view.view.window == nil)
        context["section"] = "attention"
        #expect(!controller.configurePresentation(context as NSDictionary, engine: engine))
        #expect(
            (controller.execute(context as NSDictionary) as? NSDictionary)?["ok"] as? Bool == false)
        context["section"] = "extension"
        context["uiOnly"] = true
        #expect(!controller.configurePresentation(context as NSDictionary, engine: engine))
        context["uiOnly"] = false
        let replacement = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        context["presentationID"] = replacement.presentationID.uuidString
        #expect(controller.configurePresentation(context as NSDictionary, engine: replacement))
        #expect(
            (controller.execute(
                ["operation": "stopUI", "presentationID": engine.presentationID.uuidString]
                    as NSDictionary) as? NSDictionary)?["ok"] as? Bool == false)
        await #expect(throws: ExtensionEngineError.self) {
            try await engine.invoke("attention.settings.get")
        }
        #expect(
            (controller.execute(
                ["operation": "stopUI", "presentationID": replacement.presentationID.uuidString]
                    as NSDictionary) as? NSDictionary)?["ok"] as? Bool == true)
        #expect(controller.trackingSettings == nil)
    }

    @Test func nativeOriginalTrackingControlsRenderAtCompactRegularZoomAndBothSchemes() async throws
    {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, previous) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        let model = AttentionTrackingSettingsModel(
            client: AttentionUIClient(send: { _, _ in
                try AttentionPayload.encode(AttentionSettings())
            }))
        await model.load()
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale); model.stop() }
        for width in [420.0, 900.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: AttentionTrackingSettings(model: model).environment(
                            \.automaticViewActionsEnabled, false
                        ).environment(\.colorScheme, scheme))
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(25))
                    #expect(host.window == nil && !host.subviews.isEmpty)
                    #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                    let labels = trackingLabels(host)
                    for label in [
                        "Track foreground applications", "Run local browser server",
                        "Save tracking settings", "Open Attention",
                    ] {
                        #expect(labels.contains(label), "\(label): \(labels)")
                    }
                }
            }
        }
    }
}

@MainActor private func trackingLabels(_ root: NSObject) -> Set<String> {
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: NSObject) -> Set<String> {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        let label = (object as AnyObject).accessibilityLabel?() ?? ""
        let title = (object as AnyObject).accessibilityTitle?() ?? ""
        let value = (object as? NSView)?.accessibilityValue() as? String ?? ""
        let children = (object as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
        let subviews = (object as? NSView)?.subviews ?? []
        return Set([label, title, value]).union((children + subviews).flatMap { walk($0) })
    }
    return walk(root)
}

@MainActor private final class TrackingDetailBridge: NSObject {
    @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
        guard let request = try? ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data)
        else { completion(Data()); return }
        let reply = ExtensionEngineReply(token: request.token, ok: true, payload: Data("{}".utf8))
        completion((try? ExtensionEngineWire.encode(reply)) ?? Data())
    }
    @objc func cancel(_ token: String) {}
}
