import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetSettingsTests {
    private func worker(defaults: UserDefaults) -> QuinjetWorker {
        QuinjetWorker(
            defaults: defaults,
            client: .init(execute: { arguments in
                if arguments == [
                    "-C", "/private/tmp/synthetic-review", "worktree", "list", "--json",
                ] {
                    return try JSONEncoder().encode([
                        QuinjetWorktree(
                            path: "/private/tmp/synthetic-review",
                            head: "1234567", branch: "synthetic", current: true, bare: false,
                            detached: false,
                            locked: nil, prunable: nil)
                    ])
                }
                #expect(arguments == ["capabilities", "--json"])
                return Data(
                    #"{"commands":[{"path":"quinjet tui","arguments":[{"id":"theme","possibleValues":["dracula","new-theme","dracula"]}]}]}"#
                        .utf8)
            }), automaticActions: false)
    }

    @Test func originalPreferencesUseActualCapabilitiesAndFeedOriginalCLIConfiguration()
        async throws
    {
        defer { QuinjetWorkOwnership.enable() }
        let suite = "quinjet.settings.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = worker(defaults: defaults)
        let model = QuinjetSettingsModel { try await worker.execute($0, payload: $1) }
        await model.read()
        #expect(model.state?.themes == ["dracula", "new-theme"])
        #expect(model.state?.preference == .init(terminal: "embedded", theme: "app"))
        model.setTheme("dracula")
        for _ in 0..<300 {
            if defaults.string(forKey: AppStorageKeys.Quinjet.theme) == "dracula" && !model.loading
            {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.state?.preference.theme == "dracula")
        #expect(defaults.string(forKey: AppStorageKeys.Quinjet.theme) == "dracula")
        let previousExecutable = CLIEnvironment.executableNamed
        CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/usr/bin/true") }
        defer { CLIEnvironment.executableNamed = previousExecutable }
        let reply = try await QuinjetCLIExecution.run(
            .init(arguments: ["open", "/private/tmp/synthetic-review", "--json"]), worker: worker)
        #expect(reply.exitCode == 0)
        let result = try #require(
            try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
        let arguments = try #require(result["arguments"] as? [String])
        #expect(arguments.contains("dracula"))
        #expect(worker.model.selectedTab?.holder.descriptor == nil)
        model.shutdown()
        await worker.shutdown()
    }

    @Test func originalPreferencesRejectStaleSavesInjectedFieldsAndDisabledOwner() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let suite = "quinjet.settings.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = worker(defaults: defaults)
        let first = try JSONDecoder().decode(
            QuinjetSettingsState.self,
            from: await worker.execute("quinjet.settings.read", payload: Data("{}".utf8)))
        let next = QuinjetSettingsPreference(terminal: "embedded", theme: "new-theme")
        let request = try JSONEncoder().encode(
            QuinjetSettingsMutation(baseline: first.preference, preference: next))
        let saved = try JSONDecoder().decode(
            QuinjetSettingsState.self,
            from: await worker.execute("quinjet.settings.save", payload: request))
        #expect(saved.preference == next)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("quinjet.settings.save", payload: request)
        }
        for value in [
            ["terminal": "embedded", "theme": "unadvertised"],
            ["terminal": "arbitrary-launch", "theme": "app"],
            ["terminal": "embedded", "theme": "app", "executable": "/bin/sh"],
        ] {
            await #expect(throws: ExtensionPeerError.self) {
                try await worker.execute(
                    "quinjet.settings.save",
                    payload: JSONSerialization.data(withJSONObject: [
                        "baseline": ["terminal": next.terminal, "theme": next.theme],
                        "preference": value,
                    ]))
            }
        }
        #expect(defaults.string(forKey: AppStorageKeys.Quinjet.theme) == "new-theme")
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("quinjet.settings.read", payload: Data("{}".utf8))
        }
    }

    @Test func stoppedSettingsRejectLateRepliesAndFailedSaveRetainsOriginalPreference() async throws
    {
        var pending: CheckedContinuation<Data, Error>?
        let value = QuinjetSettingsState(
            preference: .init(terminal: "embedded", theme: "app"),
            themes: ["dracula"], cmuxAvailable: false)
        let stopped = QuinjetSettingsModel { operation, _ in
            #expect(operation == "quinjet.settings.read")
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let reading = Task { await stopped.read() }
        while pending == nil { await Task.yield() }
        stopped.shutdown()
        pending?.resume(returning: try JSONEncoder().encode(value))
        await reading.value
        #expect(stopped.state == nil && !stopped.loading && stopped.error == nil)
        var saves = 0
        let failed = QuinjetSettingsModel { operation, _ in
            if operation == "quinjet.settings.read" { return try JSONEncoder().encode(value) }
            #expect(operation == "quinjet.settings.save")
            saves += 1
            throw ExtensionPeerError.unavailable
        }
        await failed.read()
        failed.setTheme("dracula")
        for _ in 0..<300 {
            if saves == 1 && !failed.loading { break }; try await Task.sleep(for: .milliseconds(1))
        }
        #expect(failed.state?.preference == value.preference && failed.error != nil)
        failed.shutdown()
    }

    @Test func originalTerminalAndThemeControlsRenderOffscreenAtOriginalSettingsWidths()
        async throws
    {
        _ = TestWindowHost.application
        let model = QuinjetSettingsModel { _, _ in
            try JSONEncoder().encode(
                QuinjetSettingsState(
                    preference: .init(terminal: "embedded", theme: "app"),
                    themes: QuinjetTheme.allCases.map(\.rawValue), cmuxAvailable: false))
        }
        await model.read()
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        let previousZoom = UIScale.current
        defer {
            model.shutdown(); UIScale.apply(previousZoom)
            for (attribute, value) in zip(attributes, previous) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        for zoom in [1.0, 1.4] {
            UIScale.apply(zoom)
            for width in [520.0, 1100.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: QuinjetSettingsPage(model: model)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.colorScheme, scheme)
                            .environment(\.compactLayout, width < 600))
                    host.frame = .init(x: 0, y: 0, width: width, height: 700)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    for _ in 0..<4 {
                        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    for label in ["Terminal", "Theme"] {
                        let control = try #require(
                            find(host, label: label),
                            "Missing \(label) at width \(width), zoom \(zoom), scheme \(scheme)")
                        let frame = (control as AnyObject).accessibilityFrame?() ?? .zero
                        #expect(frame.width > 0 && frame.height > 0)
                        #expect(frame.minX >= window.frame.minX && frame.maxX <= window.frame.maxX)
                    }
                    #expect(!TestWindowHost.isExposedOnDesktop(window))
                }
            }
        }
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        let value: Any? = (node as AnyObject).accessibilityValue?()
        if (node as AnyObject).accessibilityLabel?() == label
            || (node as AnyObject).accessibilityTitle?() == label
            || value as? String == label
        {
            return node
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = find(child, label: label, depth: depth + 1) { return result }
        }
        return nil
    }
}
