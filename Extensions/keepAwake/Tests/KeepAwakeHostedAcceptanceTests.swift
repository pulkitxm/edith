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
        var invocationPayloads: [Data] = []
        var uiChanges = 0
        let model = ControlPresentation(client: nil, defaults: ui) { operation, payload in
            operations.append(operation)
            invocationPayloads.append(payload)
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
                    KeepAwakeSettings(
                        defaults: ui,
                        synchronize: {
                            uiChanges += 1
                            model.changed()
                        })
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
        var transitions: [Bool] = []
        let pressSelector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        for requested in [true, false, true] {
            func snapshot() throws -> [Int] {
                let status = runtime.execute(["operation": "status"]) as? NSDictionary
                return [
                    ui.bool(forKey: "preventSleep") ? 1 : 0,
                    engine.bool(forKey: "preventSleep") ? 1 : 0,
                    status == nil ? 0 : 1,
                    status?["preventingSleep"] as? Bool == true ? 1 : 0,
                    operations.count, model.ready ? 1 : 0, model.running ? 1 : 0,
                    model.error == nil ? 0 : 1, model.load.isRunning ? 1 : 0,
                    try assertionCount(),
                ]
            }
            func idle() -> Bool {
                model.ready && model.running && model.error == nil && !model.load.isRunning
            }
            let baseline = try snapshot()
            let initialChanges = uiChanges
            struct Invariant: Equatable {
                let preferences: NSDictionary
                let modelState: Data
            }
            func invariant() throws -> Invariant {
                var uiPreferences = ui.persistentDomain(forName: uiSuite) ?? [:]
                var enginePreferences = engine.persistentDomain(forName: suite) ?? [:]
                uiPreferences.removeValue(forKey: "preventSleep")
                enginePreferences.removeValue(forKey: "preventSleep")
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                return .init(
                    preferences: NSDictionary(dictionary: [
                        "ui": uiPreferences, "engine": enginePreferences,
                    ]),
                    modelState: try encoder.encode(model.state))
            }
            let baselineInvariant = try invariant()
            typealias Action = KeepAwakeUIActionCompletion<Invariant>
            func actionObservation(_ control: AnyObject?, afterPress: Bool) throws
                -> Action.Observation
            {
                let suffix = operations.dropFirst(baseline[4])
                var updates = 0
                for index in baseline[4]..<operations.count {
                    switch operations[index] {
                    case "keepAwake.ui.update":
                        updates += 1
                        let update = try JSONDecoder().decode(
                            ControlPreferenceUpdate.self, from: invocationPayloads[index])
                        let values = try ControlPresentationContract.decode(
                            update.values, keys: ControlPresentationContract.writable)
                        guard update.removed.isEmpty, Set(values.keys) == ["preventSleep"],
                            let value = values["preventSleep"],
                            ControlPresentationContract.valid(value, for: "preventSleep"),
                            (value as? NSNumber)?.boolValue == requested
                        else {
                            throw KeepAwakePressFailure(description: "Unexpected checkbox update")
                        }
                    case "keepAwake.ui.read":
                        guard
                            let payload = try JSONSerialization.jsonObject(
                                with: invocationPayloads[index]) as? [String: Any], payload.isEmpty
                        else {
                            throw KeepAwakePressFailure(description: "Unexpected checkbox read")
                        }
                    default:
                        throw KeepAwakePressFailure(description: "Unexpected checkbox operation")
                    }
                }
                guard updates <= 1 else {
                    throw KeepAwakePressFailure(description: "Repeated checkbox update")
                }
                guard let engineValue = engine.object(forKey: "preventSleep"),
                    ControlPresentationContract.valid(engineValue, for: "preventSleep")
                else {
                    throw KeepAwakePressFailure(description: "Missing or invalid engine preference")
                }
                let value = ui.object(forKey: "preventSleep")
                let binding = value.flatMap {
                    ControlPresentationContract.valid($0, for: "preventSleep")
                        ? ($0 as? NSNumber).map { $0.boolValue ? 1 : 0 } : nil
                }
                let accessibility = control as? any NSAccessibilityProtocol
                let number = accessibility?.accessibilityValue() as? NSNumber
                let axValue = number.flatMap {
                    $0.doubleValue == 0 || $0.doubleValue == 1 ? $0.intValue : nil
                }
                return .init(
                    binding: binding, accessibilityValue: axValue, mutations: uiChanges,
                    invariant: try invariant(),
                    idle: model.ready && model.running && model.error == nil
                        && (!model.load.isRunning
                            || afterPress && suffix.contains("keepAwake.ui.read"))
                )
            }
            var completion = try Action(
                baseline: .init(
                    binding: baseline[0], accessibilityValue: nil, mutations: initialChanges,
                    invariant: baselineInvariant, idle: idle()),
                requested: requested ? 1 : 0)
            var observations: [[String: Bool]] = []
            var attempts = 0
            func pressFailure(_ stage: String, control: AnyObject?, accepted: Bool)
                -> KeepAwakePressFailure
            {
                let accessibility = control as? any NSAccessibilityProtocol
                let details = KeepAwakePressDiagnostics.encode(
                    attempts: attempts, accepted: accepted, baseline: baseline,
                    current: try? snapshot(), baselineValue: baseline[0],
                    currentValue: (accessibility?.accessibilityValue() as? NSNumber)?.intValue,
                    flags: [
                        "controlAvailable": control != nil,
                        "roleMatched": control?.accessibilityRole?() == .checkBox,
                        "labelMatched": control?.accessibilityLabel?() == "Keep awake",
                        "identifierMatched": control?.accessibilityIdentifier?()
                            == "keepAwake.preventSleep",
                        "enabled": control?.isAccessibilityEnabled?() == true,
                        "element": control?.isAccessibilityElement?() == true,
                        "selectorPresent": control?.responds?(to: pressSelector) == true,
                        "selectorAllowed": control?.isAccessibilitySelectorAllowed?(pressSelector)
                            == true,
                        "protocolConforms": accessibility != nil, "modelIdle": idle(),
                    ])
                return KeepAwakePressFailure(description: stage + ": " + details)
            }
            try await wait(
                "Complete original Keep awake checkbox action",
                diagnostic: {
                    if observations.isEmpty { return accessibilityDiagnostic(in: host) }
                    return diagnosticJSON([
                        "pressAttempts": attempts, "pressObservations": observations,
                    ])
                }
            ) {
                do {
                    if !completion.attempted {
                        guard try snapshot() == baseline, idle(), uiChanges == initialChanges else {
                            throw KeepAwakePressFailure(description: "Checkbox baseline changed")
                        }
                    }
                } catch {
                    throw pressFailure(
                        "Original checkbox changed or became busy before accepted press",
                        control: checkbox(in: host), accepted: false)
                }
                guard let control = checkbox(in: host) else {
                    if completion.attempted {
                        throw pressFailure(
                            "Original checkbox disappeared after its action", control: nil,
                            accepted: completion.actionReturned == true)
                    }
                    return false
                }
                let selectorPresent = control.responds?(to: pressSelector) == true
                let selectorAllowed = control.isAccessibilitySelectorAllowed?(pressSelector) == true
                let enabled = control.isAccessibilityEnabled?() == true
                let element = control.isAccessibilityElement?() == true
                let accessibility = control as? any NSAccessibilityProtocol
                let value = (accessibility?.accessibilityValue() as? NSNumber)?.intValue
                let ready = selectorPresent && selectorAllowed && enabled && element && value != nil
                let completed: Bool
                do {
                    if completion.attempted {
                        guard ready else {
                            throw KeepAwakePressFailure(
                                description: "Original checkbox became unavailable")
                        }
                        completed = try completion.complete(
                            actionObservation(control, afterPress: true))
                    } else {
                        completed = try completion.press(
                            ready: ready,
                            observation: actionObservation(control, afterPress: false),
                            perform: {
                                attempts += 1
                                return accessibility?.accessibilityPerformPress() == true
                            },
                            observe: { try actionObservation(control, afterPress: true) })
                    }
                } catch {
                    throw pressFailure(
                        "Original checkbox did not complete its single intended action",
                        control: control, accepted: completion.actionReturned == true)
                }
                observations.append([
                    "roleMatched": control.accessibilityRole?() == .checkBox,
                    "labelMatched": control.accessibilityLabel?() == "Keep awake",
                    "identifierMatched": control.accessibilityIdentifier?()
                        == "keepAwake.preventSleep",
                    "enabled": enabled, "element": element,
                    "selectorPresent": selectorPresent, "selectorAllowed": selectorAllowed,
                    "valueAvailable": value != nil,
                    "pressAccepted": completion.actionReturned == true,
                    "actionCompleted": completed,
                ])
                if observations.count > 2 { observations.removeFirst() }
                return completed
            }
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
            try #require(attempts == 1 && uiChanges == initialChanges + 1)
            try #require(
                try completion.complete(actionObservation(checkbox(in: host), afterPress: true)))
            try #require(try assertionCount() == (requested ? 1 : 0))
            try #require(
                operations.dropFirst(baseline[4]).filter { $0 == "keepAwake.ui.update" }.count == 1)
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
        while true {
            try Task.checkCancellation()
            if try condition() { return }
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
