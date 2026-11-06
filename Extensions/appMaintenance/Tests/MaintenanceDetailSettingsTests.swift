import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
@testable import AppMaintenanceExtension

@Suite(.serialized) @MainActor struct MaintenanceDetailSettingsTests {
    @Test func originalPickersRoundTripThroughTheirOwnersAndSurviveDisable() async throws {
        let suite = "synthetic.maintenance.detail." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = AppMaintenanceModel(
            defaults: defaults, inventory: { _ in [] }, discover: { _, _, _, _ in [] })
        var kind = "cask"
        var commands: [String] = []
        let model = MaintenanceSettingsModel(send: { command, payload in
            commands.append(command)
            return try await AppMaintenanceUICommands.execute(
                command, payload: payload, model: owner,
                packagePreference: { operation, payload in
                    let values = try JSONDecoder().decode([String: String].self, from: payload)
                    if operation == "homebrew.preference.write" {
                        kind = try #require(values["kind"])
                    } else {
                        #expect(operation == "homebrew.preference.read")
                    }
                    return try JSONEncoder().encode(kind)
                })
        })
        await model.load()
        #expect(model.loaded && model.packageLoaded && model.packageKind == "cask")
        model.setDestination("system")
        model.setPackageKind("formula")
        model.setDestination("user")
        await model.finish()
        #expect(model.packageKind == "formula" && kind == "formula")
        #expect(defaults.string(forKey: MaintenancePreferences.installDestination) == "user")
        #expect(
            commands == [
                "maintenance.ui.settings.read", "maintenance.ui.packageKind.read",
                "maintenance.ui.settings.write", "maintenance.ui.packageKind.write",
                "maintenance.ui.settings.write",
            ])
        model.stop()
        await owner.shutdown()
        let replacement = AppMaintenanceModel(
            defaults: defaults, inventory: { _ in [] }, discover: { _, _, _, _ in [] })
        #expect(replacement.preferences.installDestination == "user")
        #expect(kind == "formula")
        await #expect(throws: ExtensionPeerError.self) {
            try await AppMaintenanceUICommands.execute(
                "maintenance.ui.settings.read", payload: Data("{}".utf8), model: owner)
        }
        await replacement.shutdown()
    }

    @Test func boundedPackagePreferenceRejectsInvalidInputAndOwnerFailure() async throws {
        let suite = "synthetic.maintenance.invalid." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = AppMaintenanceModel(
            defaults: defaults, inventory: { _ in [] }, discover: { _, _, _, _ in [] })
        var sent = false
        for values in [["kind": "unknown"], ["kind": "formula", "extra": "value"]] {
            await #expect(throws: ExtensionPeerError.self) {
                try await AppMaintenanceUICommands.execute(
                    "maintenance.ui.packageKind.write", payload: JSONEncoder().encode(values),
                    model: owner,
                    packagePreference: { _, _ in
                        sent = true; return Data()
                    })
            }
        }
        #expect(!sent)
        let model = MaintenanceSettingsModel(send: { command, _ in
            if command == "maintenance.ui.settings.read" {
                return try JSONEncoder().encode(MaintenanceUISettings())
            }
            throw ExtensionPeerError.unavailable
        })
        await model.load()
        #expect(model.loaded && !model.packageLoaded && model.packageError != nil)
        model.stop()
        await owner.shutdown()
    }

    @Test func releaseCancelsWritesAndRejectsLateLoad() async throws {
        var continuation: CheckedContinuation<Data, Error>?
        var invalidated = false
        let model = MaintenanceSettingsModel(
            send: { _, _ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            }, invalidate: { invalidated = true })
        let loading = Task { await model.load() }
        while continuation == nil { await Task.yield() }
        model.stop()
        continuation?.resume(
            returning: try JSONEncoder().encode(MaintenanceUISettings(installDestination: "system"))
        )
        await loading.value
        #expect(!model.loaded && model.preferences.installDestination == "user" && invalidated)
        var held: CheckedContinuation<Data, Error>?
        var operations: [String] = []
        let writing = MaintenanceSettingsModel(send: { operation, _ in
            operations.append(operation)
            if operation == "maintenance.ui.settings.read" {
                return try JSONEncoder().encode(MaintenanceUISettings())
            }
            if operation == "maintenance.ui.packageKind.read" {
                return try JSONEncoder().encode("formula")
            }
            return try await withCheckedThrowingContinuation { held = $0 }
        })
        await writing.load()
        writing.setDestination("system")
        while held == nil { await Task.yield() }
        writing.setDestination("user")
        writing.stop()
        held?.resume(
            returning: try JSONEncoder().encode(MaintenanceUISettings(installDestination: "system"))
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(writing.preferences.installDestination == "user")
        #expect(operations.filter { $0 == "maintenance.ui.settings.write" }.count == 1)
    }

    @Test func factoryScopesOriginalSettingsAndPreservesMainRoutes() async throws {
        let bridge = MaintenanceDetailBridge()
        NSApplication.shared.setActivationPolicy(.prohibited)
        var created: AppMaintenanceService?
        let runtime = ExtensionServiceRuntime(
            id: "appMaintenance", role: "app", bundle: Bundle.main
        ) {
            let service = AppMaintenanceService(runtime: $0)
            created = service
            return service
        }
        let service = try #require(created)
        func configuration(
            _ id: UUID, location: String, section: String, uiOnly: Bool = false,
            extra: [String: Any] = [:]
        ) throws -> ExtensionUIConfiguration {
            var context: [String: Any] = [
                "remoteUI": true, "inProcess": true, "hostIdentifier": "test.host",
                "extensionID": "appMaintenance",
                "defaultsSuite": "test.host.extensions.appMaintenance", "uiOnly": uiOnly,
                "presentationID": id.uuidString, "location": location, "section": section,
            ]
            if !uiOnly { context["engineClient"] = bridge }
            context.merge(extra) { _, new in new }
            return try #require(ExtensionUIConfiguration(context: context as NSDictionary))
        }
        let id = UUID()
        let first = try configuration(id, location: "settings", section: "extension")
        let client = try #require(first.engineClient)
        #expect(service.configureUI(first))
        #expect(service.allowsUIDuringRetirement)
        let view = try #require(service.view(for: id))
        #expect(view.view.window == nil)
        #expect(service.acceptsStopUI(for: id))
        #expect(!service.acceptsStopUI(for: UUID()))
        #expect(!service.acceptsStopUI(for: nil))
        #expect(
            !service.configureUI(
                try configuration(
                    id, location: "settings", section: "extension", extra: ["tile": "x"])))
        #expect(
            !service.configureUI(
                try configuration(
                    id, location: "settings", section: "extension", extra: ["target": "x"])))
        #expect(service.view(for: UUID()) == nil)
        #expect(
            !service.configureUI(try configuration(id, location: "settings", section: "unrelated")))
        #expect(
            !service.configureUI(
                try configuration(id, location: "settings", section: "extension", uiOnly: true)))
        let replacementID = UUID()
        let replacement = try configuration(
            replacementID, location: "settings", section: "extension")
        #expect(service.configureUI(replacement))
        await #expect(throws: ExtensionEngineError.self) {
            try await client.invoke("maintenance.ui.settings.read")
        }
        #expect(service.view(for: id) == nil)
        #expect(service.view(for: replacementID) != nil)
        #expect(service.stopUI(for: id).isEmpty)
        #expect(service.settingsModel != nil)
        _ = service.stopUI(for: replacementID)
        #expect(service.settingsModel == nil)
        #expect(service.view(for: replacementID) == nil)
        let engineID = UUID()
        #expect(
            service.configureUI(
                try configuration(engineID, location: "main", section: "appMaintenance")))
        #expect(service.settingsModel == nil)
        #expect(service.view(for: engineID) != nil)
        for section in ["Updates", "Remove", "History", "Packages"] {
            #expect(
                !service.configureUI(
                    try configuration(UUID(), location: "main", section: section)))
        }
        await runtime.stop()
    }

    @Test func originalNativePickersRenderWithoutWindowsInEveryLayout() async throws {
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
        let model = MaintenanceSettingsModel(send: { command, _ in
            command == "maintenance.ui.settings.read"
                ? try JSONEncoder().encode(MaintenanceUISettings())
                : try JSONEncoder().encode("cask")
        })
        await model.load()
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale); model.stop() }
        for width in [420.0, 900.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: AppMaintenanceSettings(model: model).environment(
                            \.automaticViewActionsEnabled, false
                        ).environment(\.colorScheme, scheme))
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(25))
                    #expect(host.window == nil && !host.subviews.isEmpty)
                    #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                    let labels = maintenanceLabels(host)
                    #expect(labels.contains("Default package kind"), "\(labels)")
                    #expect(labels.contains("Disk image destination"), "\(labels)")
                }
            }
        }
    }
}

@MainActor private func maintenanceLabels(_ root: NSObject) -> Set<String> {
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

@MainActor private final class MaintenanceDetailBridge: NSObject {
    @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
        guard let request = try? ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data)
        else { completion(Data()); return }
        let reply = ExtensionEngineReply(token: request.token, ok: true, payload: Data("{}".utf8))
        completion((try? ExtensionEngineWire.encode(reply)) ?? Data())
    }
    @objc func cancel(_ token: String) {}
}
