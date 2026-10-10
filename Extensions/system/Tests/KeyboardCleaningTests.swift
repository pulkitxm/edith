import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI
import Testing
@testable import SystemExtension

@MainActor @Suite(.serialized) struct KeyboardCleaningTests {
    @Test func explicitPermissionRequestsNeverInstallInputTap() {
        let hardware = FixtureHardware()
        hardware.inputMonitoring = false
        let store = KeyboardCleaning(environment: hardware.environment)
        #expect(store.beginCleaning() == .inputMonitoringRequired)
        #expect(hardware.inputRequests == 1)
        #expect(hardware.tapInstalls == 0)
        #expect(hardware.overlays == 0)
        hardware.inputMonitoring = true; hardware.accessibility = false
        #expect(store.beginCleaning() == .accessibilityRequired)
        #expect(hardware.accessibilityRequests == 1)
        #expect(hardware.tapInstalls == 0)
        #expect(store.phase == .idle)
        store.shutdown()
    }

    @Test func originalCountdownAndFailsafeOwnAndReleaseEveryResource() {
        let hardware = FixtureHardware()
        let store = KeyboardCleaning(environment: hardware.environment)
        #expect(store.beginCleaning() == .arming)
        #expect(store.armingCountdown == 3)
        #expect(hardware.overlays == 2)
        #expect(hardware.tapInstalls == 0)
        #expect(store.beginCleaning() == .arming)
        #expect(hardware.overlayShows == 1)
        hardware.fire(1); hardware.fire(1)
        #expect(store.armingCountdown == 1)
        #expect(hardware.tapInstalls == 0)
        hardware.fire(1)
        #expect(store.phase == .cleaning)
        #expect(store.failsafeRemaining == 60)
        #expect(hardware.tapInstalled)
        #expect(hardware.activeTimers == 2)
        hardware.fire(5)
        #expect(hardware.tapHealthChecks == 1)
        for _ in 0..<59 { hardware.fire(1) }
        #expect(store.failsafeRemaining == 1)
        #expect(store.phase == .cleaning)
        hardware.fire(1)
        #expect(store.phase == .idle)
        #expect(hardware.activeTimers == 0)
        #expect(!hardware.tapInstalled)
        #expect(hardware.overlays == 0)
        #expect(store.armingCountdown == 0)
        #expect(store.failsafeRemaining == 0)
        store.shutdown()
    }

    @Test(arguments: [false, true]) func disableDrainsArmingAndActiveOwnersAndRejectsLateCallbacks(
        active: Bool
    ) {
        let hardware = FixtureHardware()
        var store: KeyboardCleaning? = KeyboardCleaning(environment: hardware.environment)
        weak var retained = store
        _ = store?.beginCleaning()
        if active { for _ in 0..<3 { hardware.fire(1) } }
        store?.shutdown()
        #expect(store?.phase == .idle)
        #expect(store?.beginCleaning() == .unavailable)
        #expect(hardware.activeTimers == 0)
        #expect(hardware.overlays == 0)
        #expect(!hardware.tapInstalled)
        hardware.fireRetiredCallbacks()
        #expect(hardware.tapInstalls == (active ? 1 : 0))
        #expect(hardware.tapHealthChecks == 0)
        store = nil
        #expect(retained == nil)
    }

    @Test func installationFailureRestoresKeyboardAndOverlayWithoutTimers() {
        let hardware = FixtureHardware()
        hardware.canInstallTap = false
        let store = KeyboardCleaning(environment: hardware.environment)
        _ = store.beginCleaning()
        for _ in 0..<3 { hardware.fire(1) }
        #expect(store.phase == .idle)
        #expect(store.message?.contains("could not be locked") == true)
        #expect(hardware.activeTimers == 0)
        #expect(hardware.overlays == 0)
        #expect(!hardware.tapInstalled)
        store.shutdown()
    }

    @Test func missingOverlayNeverLocksAnInvisibleKeyboard() {
        let hardware = FixtureHardware()
        hardware.canShowOverlays = false
        let store = KeyboardCleaning(environment: hardware.environment)
        #expect(store.beginCleaning() == .unavailable)
        #expect(store.phase == .idle)
        #expect(hardware.tapInstalls == 0)
        #expect(hardware.activeTimers == 0)
        store.shutdown()
    }

    @Test func boundedCommandPayloadAndCurrentSurfaceActionAdmission() async throws {
        let hardware = FixtureHardware()
        let store = KeyboardCleaning(environment: hardware.environment)
        defer { store.shutdown() }
        #expect(throws: KeyboardCleaningError.self) {
            try store.execute("system.cleanKeys", payload: Data("{\"pid\":123}".utf8))
        }
        #expect(throws: KeyboardCleaningError.self) {
            try store.execute("system.other", payload: Data())
        }
        let tile = SurfaceTile(.actions)
        let stale = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "cleanKeys")
        let response = try JSONDecoder().decode(
            KeyboardCleaningResponse.self,
            from: store.execute("system.cleanKeys", payload: Data("{}".utf8)))
        #expect(response.result == .arming)
        #expect(response.status.armingCountdown == 3)
        await #expect(throws: ExtensionPeerError.self) {
            try await SurfaceCommandService.execute(
                providerID: "system", command: "surface.perform",
                payload: stale.encoded(providerID: "system"),
                snapshot: { tile in
                    SystemSurface.snapshot(apps: [], tile: tile, cleaning: store.status)
                },
                perform: { _ in Issue.record("A stale keyboard lock action ran.") },
                privacyValues: { [:] })
        }
        let stopped = try JSONDecoder().decode(
            KeyboardCleaningStatus.self, from: store.execute("system.stopCleaning", payload: Data())
        )
        #expect(stopped.phase == .idle)
        let snapshot = SystemSurface.snapshot(apps: [], tile: tile, cleaning: store.status)
        #expect(snapshot.actions.map(\.id) == ["cleanKeys"])
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "system")
    }

    @Test func originalOverlayRendersSyntheticCountdownAndExitControl() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
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
        let hardware = FixtureHardware()
        let store = KeyboardCleaning(environment: hardware.environment)
        defer { store.shutdown() }
        _ = store.beginCleaning()
        let view = NSHostingView(rootView: CleaningOverlayView(store: store))
        view.frame = .init(x: 0, y: 0, width: 640, height: 420)
        let window = CleaningTestWindow(
            contentRect: .init(x: -10000, y: -10000, width: 640, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.fittingSize.width > 0)
        #expect(view.fittingSize.height > 0)
        #expect(
            Self.elements(view).contains {
                Self.label($0) == "Starting in 3…"
            })
        for _ in 0..<3 { hardware.fire(1) }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.phase == .cleaning)
        #expect(view.fittingSize.width > 0)
        let done = try #require(
            Self.elements(view).first {
                ($0 as AnyObject).accessibilityRole?() == .button
                    && Self.label($0) == "Done cleaning"
            })
        #expect((done as AnyObject).accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.phase == .idle)
        #expect(hardware.overlays == 0)
        #expect(!hardware.tapInstalled)
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) })
    }

    private static func label(_ node: NSObject) -> String? {
        if let label = (node as AnyObject).accessibilityLabel?(), !label.isEmpty { return label }
        let selector = NSSelectorFromString("accessibilityValue")
        return node.responds(to: selector)
            ? node.perform(selector)?.takeUnretainedValue() as? String : nil
    }

    private static func elements(_ root: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        let children = (root as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
        let views = (root as? NSView)?.subviews ?? []
        return [root] + (children + views).flatMap { elements($0, depth: depth + 1) }
    }

    @MainActor private final class FixtureHardware {
        struct Scheduled {
            let interval: TimeInterval
            let action: @MainActor () -> Void
            var active = true
        }
        var inputMonitoring = true
        var accessibility = true
        var inputRequests = 0
        var accessibilityRequests = 0
        var canInstallTap = true
        var canShowOverlays = true
        var tapInstalls = 0
        var tapInstalled = false
        var tapHealthChecks = 0
        var overlays = 0
        var overlayShows = 0
        var scheduled: [UUID: Scheduled] = [:]
        var activeTimers: Int { scheduled.values.filter(\.active).count }
        var environment: KeyboardCleaningEnvironment {
            .init(
                permissions: { (self.inputMonitoring, self.accessibility) },
                requestInputMonitoring: { self.inputRequests += 1 },
                requestAccessibility: { self.accessibilityRequests += 1 },
                installTap: {
                    self.tapInstalls += 1
                    self.tapInstalled = self.canInstallTap
                    return self.canInstallTap
                }, removeTap: { self.tapInstalled = false },
                ensureTap: { self.tapHealthChecks += 1 },
                showOverlays: { _ in
                    self.overlayShows += 1
                    self.overlays = self.canShowOverlays ? 2 : 0
                    return self.canShowOverlays
                }, hideOverlays: { self.overlays = 0 },
                schedule: { interval, action in
                    let id = UUID()
                    self.scheduled[id] = .init(interval: interval, action: action)
                    return KeyboardCleaningTimer { self.scheduled[id]?.active = false }
                })
        }
        func fire(_ interval: TimeInterval) {
            let actions = scheduled.values.filter { $0.active && $0.interval == interval }.map(
                \.action)
            for action in actions { action() }
        }
        func fireRetiredCallbacks() { for value in scheduled.values { value.action() } }
    }
}

private final class CleaningTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
