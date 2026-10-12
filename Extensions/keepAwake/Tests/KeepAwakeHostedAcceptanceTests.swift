import AppKit
import Darwin
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import IOKit.pwr_mgt
import SwiftUI
import Testing

@testable import KeepAwakeExtension

@MainActor @Suite(.serialized) struct KeepAwakeHostedAcceptanceTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["EDITH_KEEP_AWAKE_HOSTED_ACCEPTANCE"] == "1"))
    func originalCheckboxOwnsAndReleasesRealSleepAssertion() async throws {
        let environment = ProcessInfo.processInfo.environment
        for (key, value) in [
            "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS",
            "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_REPOSITORY": "pulkitxm/edith",
            "EDITH_KEEP_AWAKE_HOSTED_ACCEPTANCE": "1",
        ] {
            try #require(environment[key] == value)
        }
        try #require(["65671483", "320458784"].contains(environment["GITHUB_ACTOR_ID"] ?? ""))
        try #require(environment["EDITH_FUNCTIONAL_FIXTURE"] == nil)
        let source = try #require(environment["EXPECTED_SOURCE_SHA"])
        try #require(source == environment["GITHUB_SHA"] && source.count == 40)
        let receiptPath = try #require(environment["KEEP_AWAKE_NATIVE_RECEIPT"])
        let receipt = URL(fileURLWithPath: receiptPath)
        let root = receipt.deletingLastPathComponent()
        try #require(root.path == root.resolvingSymlinksInPath().path)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        try #require(
            attributes[.ownerAccountID] as? UInt32 == getuid()
                && attributes[.posixPermissions] as? Int == 0o700)
        for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"] {
            let path = try #require(environment[key])
            let directory = URL(fileURLWithPath: path)
            try #require(
                directory.path.hasPrefix(root.path + "/")
                    && directory.resolvingSymlinksInPath().path == directory.path)
        }
        try #require(!FileManager.default.fileExists(atPath: receipt.path))
        try #require(try assertionCount() == 0)
        let suite = "com.pulkit.edith.tests.keep-awake-" + UUID().uuidString
        let engine = try #require(UserDefaults(suiteName: suite))
        let uiSuite = suite + ".ui"
        let ui = try #require(UserDefaults(suiteName: uiSuite))
        defer {
            engine.removePersistentDomain(forName: suite)
            ui.removePersistentDomain(forName: uiSuite)
        }
        engine.set(false, forKey: "preventSleep")
        let runtime = KeepAwakeRuntime(admitFixture: { _ in nil }, makeDefaults: { _ in engine })
        try #require(
            (runtime.execute(["operation": "start", "defaultsSuite": suite]) as? NSDictionary)?[
                "ok"] as? Bool == true)
        var stopped = false
        defer { if !stopped { _ = runtime.execute(["operation": "stop"]) } }
        var operations: [String] = []
        let model = ControlPresentation(client: nil, defaults: ui) { operation, payload in
            operations.append(operation)
            return try await withCheckedThrowingContinuation { continuation in
                runtime.invoke(
                    ["token": UUID().uuidString, "command": operation, "payload": payload]
                ) { data, error in
                    if let error {
                        continuation.resume(throwing: NSError(domain: error as String, code: 1))
                    } else if let data {
                        continuation.resume(returning: data as Data)
                    } else {
                        continuation.resume(throwing: ExtensionPeerError.unavailable)
                    }
                }
            }
        }
        defer { model.stop() }
        await model.refresh()
        try #require(model.ready && model.error == nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        try #require(application.accessibilityIsAttributeSettable(enhanced))
        let previous = application.accessibilityAttributeValue(enhanced)
        application.accessibilitySetValue(true, forAttribute: enhanced)
        defer { application.accessibilitySetValue(previous, forAttribute: enhanced) }
        let host = NSHostingView(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: model) {
                    KeepAwakeSettings(defaults: ui, synchronize: { model.changed() })
                }
            })
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await wait(
            "Discover original Keep awake checkbox",
            diagnostic: { accessibilityDiagnostic(in: host) }
        ) { checkbox(in: host) != nil }
        var transitions: [Bool] = []
        var pressObservations: [[String: Bool]] = []
        for requested in [true, false, true] {
            let control = try #require(checkbox(in: host))
            let pressed = control.accessibilityPerformPress?() == true
            if pressObservations.count < 8 {
                pressObservations.append([
                    "roleMatched": control.accessibilityRole?() == .checkBox,
                    "labelMatched": control.accessibilityLabel?() == "Keep awake",
                    "identifierMatched": control.accessibilityIdentifier?()
                        == "keepAwake.preventSleep",
                    "enabled": control.isAccessibilityEnabled?() == true,
                    "element": control.isAccessibilityElement?() == true,
                    "pressAccepted": pressed,
                ])
            }
            try #require(
                pressed,
                "Original checkbox press rejected: \(diagnosticJSON(["pressObservations": pressObservations]))"
            )
            try await wait(
                "Apply original Keep awake preference \(requested)",
                diagnostic: {
                    let status = runtime.execute(["operation": "status"]) as? NSDictionary
                    return diagnosticJSON([
                        "enginePreventSleep": engine.bool(forKey: "preventSleep"),
                        "runtimeStatusAvailable": status != nil,
                        "runtimePreventingSleep": status?["preventingSleep"] as? Bool ?? false,
                        "modelErrorPresent": model.error != nil,
                        "operationCount": operations.count,
                    ])
                }
            ) {
                guard engine.bool(forKey: "preventSleep") == requested,
                    ((runtime.execute(["operation": "status"]) as? NSDictionary)?[
                        "preventingSleep"] as? Bool) == requested
                else { return false }
                return try assertionCount() == (requested ? 1 : 0)
            }
            try #require(try assertionCount() == (requested ? 1 : 0))
            try #require(operations.contains("keepAwake.ui.update"))
            try #require(model.error == nil)
            transitions.append(requested)
        }
        await model.stopAndWait()
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        stopped = true
        try #require(try assertionCount() == 0)
        try #require(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        try #require(engine.bool(forKey: "preventSleep"))
        let result: [String: Any] = [
            "schema": 1, "sourceCommit": source, "owner": "keepAwake",
            "originalCheckboxActivated": true, "productionRuntimeInvoked": true,
            "realIOKitAssertionVerified": true, "shutdownAssertionReleased": true,
            "requestedPreferencePreserved": true, "transitions": transitions,
            "syntheticPlatformAdapter": false, "workerProcessLifecycleVerified": false,
        ]
        try JSONSerialization.data(withJSONObject: result, options: .sortedKeys).write(
            to: receipt, options: [.withoutOverwriting])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }

    private func wait(
        _ phase: String, diagnostic: (() -> String)? = nil, _ condition: () throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            let beforeDeadline = ContinuousClock.now < deadline
            if !beforeDeadline {
                let details = diagnostic?() ?? "{}"
                try #require(beforeDeadline, "\(phase): \(details)")
            }
            advanceRunLoop()
            await Task.yield()
        }
    }

    private func accessibilityDiagnostic(in root: Any) -> String {
        var pending: [Any] = [root]
        var visited: Set<ObjectIdentifier> = []
        var examinedNodes = 0
        var checkboxRoles = 0
        var exactLabelMatches = 0
        var exactTitleMatches = 0
        var exactIdentifierMatches = 0
        while !pending.isEmpty && examinedNodes < 4096 {
            examinedNodes += 1
            let value = pending.removeLast()
            let object = value as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.accessibilityRole?() == .checkBox { checkboxRoles += 1 }
            if object.accessibilityLabel?() == "Keep awake" { exactLabelMatches += 1 }
            if object.accessibilityTitle?() == "Keep awake" { exactTitleMatches += 1 }
            if object.accessibilityIdentifier?() == "keepAwake.preventSleep" {
                exactIdentifierMatches += 1
            }
            if let children = object.accessibilityChildren?() {
                pending.append(contentsOf: children)
            }
            if let view = value as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return diagnosticJSON([
            "visitedNodes": visited.count,
            "examinedNodes": examinedNodes,
            "checkboxRoles": checkboxRoles,
            "exactLabelMatches": exactLabelMatches,
            "exactTitleMatches": exactTitleMatches,
            "exactIdentifierMatches": exactIdentifierMatches,
            "traversalCapReached": !pending.isEmpty,
        ])
    }

    private func diagnosticJSON(_ values: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys),
            data.count <= 1024, let text = String(data: data, encoding: .utf8)
        else { return "{\"diagnosticEncodingFailed\":true}" }
        return text
    }

    private func advanceRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func checkbox(in root: Any) -> AnyObject? {
        var pending: [Any] = [root]
        var visited: Set<ObjectIdentifier> = []
        var matches: [AnyObject] = []
        var examinedNodes = 0
        while let value = pending.popLast() {
            guard examinedNodes < 4096 else { return nil }
            examinedNodes += 1
            let object = value as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.accessibilityRole?() == .checkBox,
                object.accessibilityLabel?() == "Keep awake",
                object.accessibilityIdentifier?() == "keepAwake.preventSleep"
            {
                matches.append(object)
                guard matches.count == 1 else { return nil }
            }
            if let children = object.accessibilityChildren?() {
                pending.append(contentsOf: children)
            }
            if let view = value as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func assertionCount() throws -> Int {
        var values: Unmanaged<CFDictionary>?
        try #require(IOPMCopyAssertionsByProcess(&values) == kIOReturnSuccess)
        let dictionary = try #require(values?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
        return (dictionary[NSNumber(value: getpid())] ?? []).filter {
            $0[kIOPMAssertionNameKey as String] as? String == "Edith: Keep Awake is on"
                && $0[kIOPMAssertionLevelKey as String] as? Int == kIOPMAssertionLevelOn
        }.count
    }
}
