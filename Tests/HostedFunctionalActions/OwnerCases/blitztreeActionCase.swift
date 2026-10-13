import AppKit
import ApplicationServices
import Darwin
import EdithExtensionSupport
import Foundation
import FunctionalActionContract
import SwiftUI

@testable import BlitzTreeExtension

@MainActor
final class BlitzTreeActionCase: HostedFunctionalActionCase {
    static let owner = "blitztree"
    static let activationOperation = "blitztree.ui.trash"
    private let transport: HostedFunctionalActionTransport
    private let model: BlitzTreeModel
    private let readSaved: @MainActor () async throws -> Data?
    private let directory: URL
    private var window: NSWindow?
    private var accessibility: [(NSAccessibility.Attribute, Any?)] = []
    private let application = AXUIElementCreateApplication(getpid())

    init(
        transport: HostedFunctionalActionTransport,
        readSaved: @escaping @MainActor () async throws -> Data?
    ) throws {
        guard transport.context.owner == Self.owner,
            transport.context.activationOperation == Self.activationOperation
        else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        self.readSaved = readSaved
        directory = try transport.context.ownedPath(named: "scan-directory", kind: "directory")
        let victim = try transport.context.ownedPath(named: "victim", kind: "file")
        guard victim == directory.appendingPathComponent("victim.bin") else {
            throw HostedFunctionalActionError.invalid
        }
        model = BlitzTreeModel(engineClient: try transport.makeEngineClient())
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context, AXIsProcessTrusted() else {
            throw HostedFunctionalActionError.invalid
        }
        do {
            try await transport.requireCurrent()
            await model.refreshRemote()
            guard model.error == nil, model.root == nil, !model.scanning, !model.removing else {
                throw HostedFunctionalActionError.invalid
            }
            let controller = NSHostingController(rootView: BlitzTreePage(model: model))
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.title = "Synthetic BlitzTree " + context.session
            self.window = window
            _ = NSApplication.shared
            for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                let key = NSAccessibility.Attribute(rawValue: attribute)
                accessibility.append((key, NSApp.accessibilityAttributeValue(key)))
                NSApp.accessibilitySetValue(true, forAttribute: key)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let deadline = ContinuousClock.now + .seconds(10)
            try await press(try await control("Choose folder", deadline: deadline))
            _ = try await control("Scan", deadline: deadline)
            try key(5, flags: [.maskCommand, .maskShift])
            let field = try await wait(deadline: deadline) {
                guard
                    let value = try self.attribute(self.application, kAXFocusedUIElementAttribute),
                    CFGetTypeID(value) == AXUIElementGetTypeID()
                else { return nil }
                let field = unsafeDowncast(value, to: AXUIElement.self)
                guard try self.attribute(field, kAXRoleAttribute) as? String == kAXTextFieldRole,
                    try self.attribute(field, kAXSubroleAttribute) as? String
                        != kAXSecureTextFieldSubrole
                else { return nil }
                return field
            }
            try await transport.requireCurrent()
            guard
                AXUIElementSetAttributeValue(
                    field, kAXValueAttribute as CFString, directory.path as CFString) == .success,
                try attribute(field, kAXValueAttribute) as? String == directory.path
            else { throw HostedFunctionalActionError.invalid }
            try key(36, flags: [])
            let scanCount = transport.originalInvocationCount
            try await press(try await control("Scan", deadline: deadline))
            try await transport.waitForOriginalInvocation("blitztree.ui.scan", after: scanCount)
            try await waitModel { self.model.report?.summary.fileCount == 1 }
            guard model.root == directory.path, model.scannedEntries == 2 else {
                throw HostedFunctionalActionError.invalid
            }
            try await press(try await control("Move to Trash", help: true, deadline: deadline))
            let trashCount = transport.originalInvocationCount
            try await press(try await control("Move to Trash", deadline: deadline))
            try await transport.waitForOriginalInvocation(
                Self.activationOperation, after: trashCount)
            try await waitModel { self.model.report?.summary.fileCount == 0 }
            guard model.scannedEntries == 1 else { throw HostedFunctionalActionError.invalid }
        } catch {
            await shutdownPresentation()
            throw error
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("blitztree.ui.snapshot")
        let snapshot = try JSONDecoder().decode(BlitzTreeUISnapshot.self, from: bytes)
        guard snapshot.root == directory.path, snapshot.report?.summary.fileCount == 0,
            snapshot.scannedEntries == 1, snapshot.error == nil,
            !snapshot.scanning, !snapshot.removing
        else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try JSONSerialization.data(withJSONObject: ["entries": 1], options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let expected: [String: Any] = [
            "victim": ["bytes": ["present": false], "sha256": ["present": false]],
            "private-trash": [
                "bytes": ["present": true, "value": 4096],
                "sha256": [
                    "present": true,
                    "value": "fa348f8e8bdec968196a69ee608e4844220726ebfc003ba533594f8d5f1be16e",
                ],
            ],
        ]
        guard let bytes = try await readSaved(), bytes.count <= 4096,
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func shutdownPresentation() async {
        await model.shutdown()
        for (attribute, value) in accessibility {
            NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
        }
        accessibility.removeAll()
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }

    private func waitModel(_ complete: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !complete() || model.scanning || model.removing || model.ownedOperationCount != 0 {
            try await transport.requireCurrent()
            guard model.error == nil, ContinuousClock.now < deadline else {
                throw HostedFunctionalActionError.invalid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success || result == .attributeUnsupported || result == .noValue else {
            throw HostedFunctionalActionError.invalid
        }
        return value
    }

    private func control(_ label: String, help: Bool = false, deadline: ContinuousClock.Instant)
        async throws -> AXUIElement
    {
        try await wait(deadline: deadline) {
            var pending = [self.application]
            var visited: [AXUIElement] = []
            var matches: [AXUIElement] = []
            while let element = pending.popLast() {
                if visited.contains(where: { CFEqual($0, element) }) { continue }
                guard visited.count < 10000 else { throw HostedFunctionalActionError.invalid }
                visited.append(element)
                if try self.attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
                    try self.attribute(element, help ? kAXHelpAttribute : kAXTitleAttribute)
                        as? String == label,
                    try self.attribute(element, kAXEnabledAttribute) as? Bool == true
                {
                    matches.append(element)
                }
                pending.append(
                    contentsOf: try self.attribute(element, kAXChildrenAttribute) as? [AXUIElement]
                        ?? [])
            }
            guard matches.count <= 1 else { throw HostedFunctionalActionError.invalid }
            return matches.first
        }
    }

    private func wait(deadline: ContinuousClock.Instant, _ value: () throws -> AXUIElement?)
        async throws
        -> AXUIElement
    {
        while ContinuousClock.now < deadline {
            try await transport.requireCurrent()
            if let element = try value() { return element }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HostedFunctionalActionError.invalid
    }

    private func press(_ element: AXUIElement) async throws {
        try await transport.requireCurrent()
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw HostedFunctionalActionError.invalid
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { throw HostedFunctionalActionError.invalid }
        down.flags = flags; up.flags = flags
        down.postToPid(getpid()); up.postToPid(getpid())
    }
}
