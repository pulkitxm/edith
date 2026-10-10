import Foundation
import Testing
import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import SwiftUI

@testable import AttentionNative

@MainActor
@Suite(.serialized)
struct AttentionWorkerContractTests {
    @Test(arguments: [false, true])
    func originalHomeFocusControlsWriteOnlyTheOwnedRepository(remote: Bool) async throws {
        let fixture = try AttentionWorkerFixture()
        defer { fixture.remove() }
        let deniedRoot = fixture.root.appendingPathComponent("must-remain-absent")
        let uiClient: AttentionUIClient? =
            remote
            ? AttentionUIClient(send: { operation, payload in
                try await AttentionUICommands.execute(
                    operation, payload: payload, repository: fixture.repository,
                    service: fixture.service)
            }) : nil
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
        var opened = 0
        var tile = SurfaceTile(.focus)
        tile.focusMinutes = 25
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = AttentionTestWindowHost.window(
            contentRect: .init(x: 0, y: 0, width: 360, height: 260))
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        func settle() async {
            for _ in 0..<8 {
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        func render(visible: Bool) async {
            host.rootView = AnyView(
                AttentionHomeFocusCard(
                    tile: tile,
                    repository: remote ? .init(root: deniedRoot) : fixture.repository,
                    uiClient: uiClient, open: { _ in opened += 1 }
                )
                .environment(\.windowVisible, visible)
                .transaction { $0.animation = nil })
            await settle()
        }
        await render(visible: true)
        let start = try #require(find(host, label: "Start focus"))
        _ = (start as AnyObject).accessibilityPerformPress?()
        await settle()
        #expect(fixture.repository.activeFocus()?.plannedDuration == 1500)
        #expect(find(host, label: "Deep work") != nil)
        #expect(find(host, label: "Finish") != nil)
        let open = try #require(find(host, label: "Open Focus timer"))
        _ = (open as AnyObject).accessibilityPerformPress?()
        #expect(opened == 1)
        tile.showActions = false
        await render(visible: false)
        #expect(find(host, label: "Start focus") == nil)
        #expect(find(host, label: "Finish") == nil)
        #expect(find(host, label: "Open Focus timer") == nil)
        #expect(fixture.repository.activeFocus()?.plannedDuration == 1500)
        tile.showActions = true
        await render(visible: true)
        let finish = try #require(find(host, label: "Finish"))
        _ = (finish as AnyObject).accessibilityPerformPress?()
        await settle()
        #expect(fixture.repository.activeFocus() == nil)
        #expect(find(host, label: "Start focus") != nil)
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        #expect(!FileManager.default.fileExists(atPath: deniedRoot.path))
        uiClient?.stop()
        await fixture.service.stop()
        try fixture.database.close()
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        let selector = NSSelectorFromString("accessibilityValue")
        if node.responds(to: selector),
            node.perform(selector)?.takeUnretainedValue() as? String == label
        {
            return node
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        for child in (node as? NSView)?.subviews ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    @Test func sourceSelectionAndHiddenFieldsBoundTheRenderedActivity() async throws {
        let fixture = try AttentionWorkerFixture()
        defer { fixture.remove() }
        let now = Date()
        try fixture.repository.append(
            AttentionEvent(
                id: "app", startedAt: now.addingTimeInterval(-120), duration: 30,
                source: .application, appName: "Fixture Editor"))
        try fixture.repository.append(
            AttentionEvent(
                id: "web", startedAt: now.addingTimeInterval(-60), duration: 20, source: .browser,
                appName: "Fixture Browser", domain: "example.test"))
        var tile = SurfaceTile(.ability("attention"))
        tile.sourceIDs = ["browser"]
        tile.hiddenFields = ["active"]
        let surface = AttentionSurface(repository: fixture.repository, service: fixture.service)
        let request = try SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
            providerID: "attention")
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute("surface.snapshot", payload: request), providerID: "attention"
        )
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.allSatisfy { $0.sourceID == "browser" })
        #expect(snapshot.metrics.isEmpty)
        #expect(
            Set(snapshot.sources.map(\.id)) == Set(AttentionEventSource.allCases.map(\.rawValue)))
        await fixture.service.stop()
        try fixture.database.close()
    }

    @Test func focusActionsAreAdmittedOnlyInTheCurrentVisibleState() async throws {
        let fixture = try AttentionWorkerFixture()
        defer { fixture.remove() }
        let surface = AttentionSurface(repository: fixture.repository, service: fixture.service)
        let tile = SurfaceTile(.focus)
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let start = try SurfaceActionRequest(snapshot: request, actionID: "focus.start.25").encoded(
            providerID: "attention")
        let running = try SurfaceSnapshot.decode(
            try await surface.execute("surface.perform", payload: start), providerID: "attention")
        #expect(running.actions.map(\.id) == ["focus.finish"])
        #expect(fixture.repository.activeFocus()?.plannedDuration == 1500)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await surface.execute("surface.perform", payload: start)
        }
        var hidden = tile
        hidden.showActions = false
        let hiddenStop = try SurfaceActionRequest(
            snapshot: .init(target: .home, tile: hidden), actionID: "focus.finish"
        ).encoded(providerID: "attention")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await surface.execute("surface.perform", payload: hiddenStop)
        }
        #expect(fixture.repository.activeFocus() != nil)
        let stop = try SurfaceActionRequest(snapshot: request, actionID: "focus.finish").encoded(
            providerID: "attention")
        _ = try await surface.execute("surface.perform", payload: stop)
        #expect(fixture.repository.activeFocus() == nil)
        await fixture.service.stop()
        try fixture.database.close()
    }

    @Test func presentationPrivacySuppressesHistoryAndMutations() async throws {
        let fixture = try AttentionWorkerFixture()
        defer { fixture.remove() }
        let surface = AttentionSurface(
            repository: fixture.repository, service: fixture.service,
            privacyValues: { ["active": "1", "blurAttention": "1"] })
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.focus))
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "attention")),
            providerID: "attention")
        #expect(snapshot.rows.isEmpty && snapshot.metrics.isEmpty && snapshot.actions.isEmpty)
        let start = try SurfaceActionRequest(snapshot: request, actionID: "focus.start.25").encoded(
            providerID: "attention")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await surface.execute("surface.perform", payload: start)
        }
        #expect(fixture.repository.activeFocus() == nil)
        await fixture.service.stop()
        try fixture.database.close()
    }

    @Test func fixtureCollectionNeverObservesTheDesktopOrStartsBrowserListeners() async throws {
        let fixture = try AttentionWorkerFixture()
        defer { fixture.remove() }
        try fixture.repository.saveSettings(
            .init(isEnabled: true, trackingEnabled: true, browserTrackingEnabled: true))
        let data = try #require(try await fixture.service.run())
        let status = try AttentionPayload.decode(AttentionRuntimeSnapshot.self, from: data)
        #expect(!status.browserListening && status.port == nil)
        #expect(try await fixture.service.hasEvents() == false)
        await fixture.service.start()
        await fixture.service.stop()
        await #expect(throws: CancellationError.self) { _ = try await fixture.service.run() }
        try fixture.database.close()
    }

    @Test func disabledFaviconTransportNeverOpensANetworkRequest() async throws {
        let fixture = try AttentionWorkerFixture()
        defer { fixture.remove() }
        let service = FaviconService(
            directory: fixture.root.appendingPathComponent("cache"), allowsNetwork: false)
        #expect(try await service.data(for: URL(string: "https://example.test/icon.png")!) == nil)
        await service.stop()
        await #expect(throws: AttentionServiceError.self) {
            _ = try await service.data(for: URL(string: "https://example.test/icon.png")!)
        }
        await fixture.service.stop()
        try fixture.database.close()
    }
}

private struct AttentionWorkerFixture {
    let root: URL
    let database: AttentionDatabase
    let repository: AttentionRepository
    let service: AttentionBackgroundService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attention-worker-\(UUID().uuidString)")
        database = try AttentionDatabase(url: root.appendingPathComponent("history.sqlite"))
        repository = AttentionRepository(
            root: root, eventSink: AttentionEventStore(store: database))
        service = AttentionBackgroundService(
            store: database, root: root, cloudDirectory: root.appendingPathComponent("cloud"),
            cloudAvailable: { false }, collectsSystemActivity: false)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
