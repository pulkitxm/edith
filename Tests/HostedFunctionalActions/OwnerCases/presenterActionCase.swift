import AppKit
import SwiftUI
import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import PresenterExtension

@MainActor
final class PresenterActionCase: HostedFunctionalActionCase {
    static let owner = "presenter"
    static let activationOperation = "presenter.ui.update"
    private let transport: HostedFunctionalActionTransport
    private let presentation: ControlPresentation
    private var window: NSWindow?
    private var accessibility: [(NSAccessibility.Attribute, Any?)] = []

    init(transport: HostedFunctionalActionTransport) throws {
        let context = transport.context
        let environment = ProcessInfo.processInfo.environment
        guard context.owner == Self.owner,
            environment["EDITH_APPLICATION_IDENTIFIER"] == context.hostIdentifier,
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == context.home,
            environment["HOME"] == context.home,
            environment["CFFIXED_USER_HOME"] == context.home,
            environment["EDITH_SHARED_DEFAULTS_SUITE"]
                == context.hostIdentifier + ".functional.ui." + Self.owner + "." + context.phase
        else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        presentation = ControlPresentation(client: try transport.makeEngineClient())
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        await presentation.refresh()
        guard presentation.ready, presentation.active else {
            throw HostedFunctionalActionError.invalid
        }
        let controller = NSHostingController(
            rootView: Form { PresenterRows(presentation: presentation) }.formStyle(.grouped))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        let controls = find(controller.view, label: "Manual presenter mode")
        guard controls.count == 1 else { throw HostedFunctionalActionError.invalid }
        if SharedDefaults.store.bool(forKey: "presenterMode") { try await press(controls[0]) }
        guard !SharedDefaults.store.bool(forKey: "presenterMode") else {
            throw HostedFunctionalActionError.invalid
        }
        try await press(controls[0])
        guard SharedDefaults.store.bool(forKey: "presenterMode") else {
            throw HostedFunctionalActionError.invalid
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability(Self.owner)))
        let bytes = try await transport.readAuthoritative(
            "surface.snapshot", payload: request.encoded(providerID: Self.owner))
        let snapshot = try SurfaceSnapshot.decode(bytes, providerID: Self.owner)
        guard snapshot.rows.first(where: { $0.id == "presenter" })?.value == "Presenting" else {
            throw HostedFunctionalActionError.invalid
        }
        return bytes
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("presenter.ui.read")
        let packet = try JSONDecoder().decode(ControlPresentationPacket.self, from: bytes)
        let values = try ControlPresentationContract.decode(
            packet.preferences, keys: ControlPresentationContract.readable)
        guard let active = values["presenterMode"] as? Bool, active else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: ["presenterMode": active], options: [.sortedKeys])
    }

    func shutdownPresentation() async {
        presentation.stop()
        for (attribute, value) in accessibility {
            NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
        }
        accessibility.removeAll()
        window?.orderOut(nil)
        window?.contentViewController = nil
        window?.close()
        window = nil
    }

    private func press(_ control: NSObject) async throws {
        let before = transport.originalInvocationCount
        guard (control as AnyObject).accessibilityPerformPress?() == true else {
            throw HostedFunctionalActionError.invalid
        }
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
        await Task.yield()
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
