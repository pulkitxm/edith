import AppKit
import EdithExtensionSupport
import Foundation
import FunctionalActionContract
import SwiftUI

@testable import NotchShelfExtension

@MainActor
final class NotchShelfActionCase: HostedFunctionalActionCase {
    static let owner = "notchShelf"
    static let activationOperation = "notch.settings.write"
    private let transport: HostedFunctionalActionTransport
    private let model: NotchSettingsModel
    private let readSaved: @MainActor () async throws -> Data?
    private var window: NSWindow?
    private var accessibility: [(NSAccessibility.Attribute, Any?)] = []

    init(
        transport: HostedFunctionalActionTransport,
        readSaved: @escaping @MainActor () async throws -> Data?
    ) throws {
        let context = transport.context
        guard context.owner == Self.owner,
            context.activationOperation == Self.activationOperation
        else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        self.readSaved = readSaved
        model = NotchSettingsModel { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        do {
            try await transport.requireCurrent()
            await model.refresh()
            guard model.available, model.error == nil, !model.busy else {
                throw HostedFunctionalActionError.invalid
            }
            let controller = NSHostingController(rootView: NotchSettingsPage(model: model))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 640, height: 960),
                styleMask: [.titled], backing: .buffered, defer: false)
            self.window = window
            window.contentViewController = controller
            window.orderBack(nil)
            _ = NSApplication.shared
            for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                let key = NSAccessibility.Attribute(rawValue: attribute)
                accessibility.append((key, NSApp.accessibilityAttributeValue(key)))
                NSApp.accessibilitySetValue(true, forAttribute: key)
            }
            for _ in 0..<10 {
                window.layoutIfNeeded()
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let controls = find(controller.view, label: "Require ⌥ to trigger")
            guard controls.count == 1 else { throw HostedFunctionalActionError.invalid }
            if model.snapshot.preferences[AppStorageKeys.Notch.shelfRequireOption] == "1" {
                try await press(controls[0])
            }
            guard model.snapshot.preferences[AppStorageKeys.Notch.shelfRequireOption] == "0" else {
                throw HostedFunctionalActionError.invalid
            }
            try await press(controls[0])
            guard model.snapshot.preferences[AppStorageKeys.Notch.shelfRequireOption] == "1" else {
                throw HostedFunctionalActionError.invalid
            }
        } catch {
            await shutdownPresentation()
            throw error
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        let snapshot = try await read(context)
        guard snapshot.preferences[AppStorageKeys.Notch.shelfRequireOption] == "1" else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: ["requireOption": "1"], options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        guard let bytes = try await readSaved(), bytes.count <= 1_048_576 else {
            throw HostedFunctionalActionError.invalid
        }
        let expected = try JSONSerialization.data(
            withJSONObject: ["preferences": ["requireOption": ["present": true, "value": true]]],
            options: [.sortedKeys])
        let value = try JSONSerialization.jsonObject(with: bytes)
        guard try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) == expected
        else {
            throw HostedFunctionalActionError.invalid
        }
        try await transport.requireCurrent()
        return expected
    }

    private func read(_ context: HostedFunctionalActionContext) async throws
        -> NotchSettingsSnapshot
    {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("notch.settings.read")
        let snapshot = try JSONDecoder().decode(NotchSettingsSnapshot.self, from: bytes)
        try snapshot.validate()
        try await transport.requireCurrent()
        return snapshot
    }

    func shutdownPresentation() async {
        await model.stopAndWait()
        for (attribute, value) in accessibility {
            NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
        }
        accessibility.removeAll()
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }

    private func press(_ control: NSObject) async throws {
        try await transport.requireCurrent()
        let before = transport.originalInvocationCount
        guard (control as AnyObject).accessibilityPerformPress?() == true else {
            throw HostedFunctionalActionError.invalid
        }
        try await transport.waitForOriginalInvocation("notch.settings.write", after: before)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.busy {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw HostedFunctionalActionError.invalid }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await transport.requireCurrent()
        guard model.error == nil else { throw HostedFunctionalActionError.invalid }
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        if (node as AnyObject).accessibilityLabel?() == label,
            (node as AnyObject).accessibilityRole?() as? String
                == NSAccessibility.Role.checkBox.rawValue
        {
            return [node]
        }
        let children = (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
        if !children.isEmpty {
            return children.flatMap { find($0, label: label, depth: depth + 1) }
        }
        if let view = node as? NSView {
            return view.subviews.flatMap { find($0, label: label, depth: depth + 1) }
        }
        return []
    }
}
