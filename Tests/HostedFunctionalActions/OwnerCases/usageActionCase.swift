import AppKit
import EdithExtensionSupport
import Foundation
import FunctionalActionContract
import SwiftUI

@testable import UsageExtension

@MainActor
final class UsageActionCase: HostedFunctionalActionCase {
    static let owner = "usage"
    static let activationOperation = "usage.ui.preferences.set"
    private let transport: HostedFunctionalActionTransport
    private let client: UsageUIClient
    private var window: NSWindow?
    private var accessibility: [(NSAccessibility.Attribute, Any?)] = []

    init(transport: HostedFunctionalActionTransport) throws {
        let context = transport.context
        let environment = ProcessInfo.processInfo.environment
        guard context.owner == Self.owner, environment["HOME"] == context.home,
            environment["CFFIXED_USER_HOME"] == context.home,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == context.hostIdentifier + ".functional.ui.usage." + context.phase
        else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        client = UsageUIClient(invoke: { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        })
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await client.prepare()
        let controller = NSHostingController(rootView: Form {
            UsageSettingsRows()
        }.environment(\.usageUIClient, client))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 1800),
            styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        window.contentViewController = controller
        window.orderBack(nil)
        _ = NSApplication.shared
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let attribute = NSAccessibility.Attribute(rawValue: name)
            accessibility.append((attribute, NSApp.accessibilityAttributeValue(attribute)))
            NSApp.accessibilitySetValue(true, forAttribute: attribute)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var controls: [NSObject] = []
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controls = find(controller.view)
            if controls.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard controls.count == 1 else { throw HostedFunctionalActionError.invalid }
        if SharedDefaults.store.bool(forKey: AppStorageKeys.Budget.enabled) {
            try await press(controls[0])
        }
        guard !SharedDefaults.store.bool(forKey: AppStorageKeys.Budget.enabled) else {
            throw HostedFunctionalActionError.invalid
        }
        try await press(controls[0])
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let value = try JSONDecoder().decode(
            UsageUIPreferences.self, from: await transport.readAuthoritative("usage.ui.preferences"))
        guard value.values[AppStorageKeys.Budget.enabled] == .bool(true) else {
            throw HostedFunctionalActionError.invalid
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
        await client.stopAndWait()
        for (attribute, value) in accessibility {
            NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
        }
        accessibility.removeAll()
    }

    private func press(_ control: NSObject) async throws {
        let count = transport.originalInvocationCount
        guard (control as AnyObject).accessibilityPerformPress?() == true else {
            throw HostedFunctionalActionError.invalid
        }
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        try await Task.sleep(for: .milliseconds(50))
    }

    private func find(_ node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        if let label = (node as AnyObject).accessibilityLabel?() as? String,
            label.hasPrefix("Pace my "), label.hasSuffix(" usage"),
            (node as AnyObject).accessibilityRole?() as? String == NSAccessibility.Role.checkBox.rawValue
        { return [node] }
        let children = (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
        if !children.isEmpty { return children.flatMap { find($0, depth: depth + 1) } }
        return (node as? NSView)?.subviews.flatMap { find($0, depth: depth + 1) } ?? []
    }
}
