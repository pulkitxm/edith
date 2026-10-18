import AppKit
import EdithExtensionSupport
import Foundation
import FunctionalActionContract
import SwiftUI

@testable import KeepAwakeExtension

@MainActor
final class KeepAwakeActionCase: HostedFunctionalActionCase {
    static let owner = "keepAwake"
    static let activationOperation = "keepAwake.ui.update"
    private let transport: HostedFunctionalActionTransport
    private let defaults: UserDefaults
    private let presentation: ControlPresentation
    private var window: NSWindow?
    private var accessibility: [(NSAccessibility.Attribute, Any?)] = []

    init(transport: HostedFunctionalActionTransport) throws {
        let context = transport.context
        guard context.owner == Self.owner,
            let defaults = UserDefaults(
                suiteName: context.hostIdentifier + ".functional.ui.keepAwake." + context.phase)
        else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        self.defaults = defaults
        presentation = ControlPresentation(client: nil, defaults: defaults) { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        await presentation.refresh()
        guard presentation.ready, presentation.active else {
            throw HostedFunctionalActionError.invalid
        }
        let controller = NSHostingController(
            rootView: KeepAwakeSettings(
                defaults: defaults,
                synchronize: { [presentation] in
                    presentation.changed()
                }))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
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
        let controls = find(controller.view, label: "Keep awake")
        guard controls.count == 1 else { throw HostedFunctionalActionError.invalid }
        if defaults.bool(forKey: "preventSleep") { try await press(controls[0]) }
        guard !defaults.bool(forKey: "preventSleep") else {
            throw HostedFunctionalActionError.invalid
        }
        try await press(controls[0])
        guard defaults.bool(forKey: "preventSleep") else {
            throw HostedFunctionalActionError.invalid
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability(Self.owner)))
        let bytes = try await transport.readAuthoritative(
            "surface.snapshot", payload: request.encoded(providerID: Self.owner))
        let snapshot = try SurfaceSnapshot.decode(bytes, providerID: Self.owner)
        guard snapshot.metrics.first(where: { $0.id == "status" })?.value == "On" else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: ["preventingSleep": true], options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("keepAwake.ui.read")
        let packet = try JSONDecoder().decode(ControlPresentationPacket.self, from: bytes)
        let values = try ControlPresentationContract.decode(
            packet.preferences, keys: ControlPresentationContract.readable)
        guard values["preventSleep"] as? Bool == true else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: ["preventSleep": true], options: [.sortedKeys])
    }

    func shutdownPresentation() async {
        await presentation.stopAndWait()
        for (attribute, value) in accessibility {
            NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
        }
        accessibility.removeAll()
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }

    private func press(_ control: NSObject) async throws {
        let before = transport.originalInvocationCount
        guard (control as AnyObject).accessibilityPerformPress?() == true else {
            throw HostedFunctionalActionError.invalid
        }
        try await transport.waitForOriginalInvocation("keepAwake.ui.update", after: before)
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
