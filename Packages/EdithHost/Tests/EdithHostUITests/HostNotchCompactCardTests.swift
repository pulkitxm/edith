import AppKit
import EdithExtensionUI
import EdithHostCore
import SwiftUI
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchCompactCardTests {
    @Test func originalCompactCardRendersAndItsActualButtonsUseIssuedActionsAndOneOpenCallback()
        async throws
    {
        _ = TestWindowHost.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let oldAccessibility = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, old) in zip(attributes, oldAccessibility) {
                NSApp.accessibilitySetValue(old ?? false, forAttribute: attribute)
            }
        }
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (width, zoom, scheme, dense) in [
            (280.0, 1.0, ColorScheme.light, true), (560.0, 1.0, ColorScheme.dark, false),
            (420.0, 1.5, ColorScheme.light, true), (700.0, 1.5, ColorScheme.dark, false),
        ] {
            UIScale.apply(zoom)
            let fixture = CompactCardFixture(
                widget: .desk, versions: ["clipboard": "1", "emoji": "2"], dense: dense)
            try await fixture.model.refresh()
            let host = NSHostingView(
                rootView: HostNotchCompactCard(
                    model: fixture.model,
                    layout: .init(tiles: [fixture.origin.tile]), measured: { _ in }
                )
                .environment(\.colorScheme, scheme).environment(
                    \.automaticViewActionsEnabled, false
                )
                .transaction { $0.animation = nil })
            host.frame = .init(x: 0, y: 0, width: width, height: 800)
            let panel = HostNotchPanel()
            panel.contentView = host
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!panel.isVisible && !panel.isKeyWindow)
            #expect(host.fittingSize.height.isFinite && host.fittingSize.height > 30)
            let open = try #require(compactControls(host, label: "Open Desk tools").first)
            #expect(compactControls(host, label: "Open Desk tools").count == 1)
            #expect((open as AnyObject).accessibilityPerformPress?() == true)
            await fixture.wait { fixture.navigation.count == 1 }
            #expect(fixture.navigation.first?.0 == fixture.origin)
            #expect(fixture.navigation.first?.0.tile.widget.destination == "desk")
            let action = try #require(compactControls(host, label: "Change").first)
            #expect((action as AnyObject).accessibilityPerformPress?() == true)
            for _ in 0..<100 {
                if await fixture.gate.performed().count == 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await fixture.gate.performed().count == 1)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            await fixture.model.stop()
            panel.close()
        }
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func compactLeaseStopsOwnedRequestsWhenItsOriginalPanelDetaches() async throws {
        _ = TestWindowHost.application
        let fixture = CompactCardFixture(widget: .github, versions: ["quinjet": "1"])
        let request = HostExtensionContentRequest(
            extensionID: "quinjet", location: "notch",
            section: "surface.card", presentationID: fixture.origin.cardPresentationID,
            surface: .init(target: .notch, tile: fixture.origin.tile))
        let lease = HostNotchCompactController.lease(
            request: request, model: fixture.model,
            layout: .init(tiles: [fixture.origin.tile]), automatic: false)
        let panel = HostNotchPanel()
        panel.contentViewController = lease.controller
        lease.apply(compact: true, visible: true, width: 400)
        try await fixture.model.refresh()
        #expect(lease.controller.children.count == 1 && !panel.isVisible)
        lease.apply(compact: true, visible: false, width: 400)
        #expect(fixture.model.providers.isEmpty)
        await fixture.gate.hold()
        let reading = Task { try await fixture.model.refresh() }
        for _ in 0..<100 {
            if await fixture.gate.started() { break }; try await Task.sleep(for: .milliseconds(5))
        }
        let closing = Task { try await lease.close() }
        await Task.yield()
        await fixture.gate.release()
        _ = try? await reading.value
        try await closing.value
        #expect(lease.closed && fixture.model.pendingCount == 0 && fixture.model.providers.isEmpty)
        #expect(lease.controller.parent == nil && lease.controller.view.superview == nil)
        panel.close()
    }

    @Test func sharedOriginalCardsUseRealProviderSnapshotsAndPreserveTileSourceAndActionControls()
        async throws
    {
        let fixture = CompactCardFixture(widget: .desk, versions: ["clipboard": "1", "emoji": "2"])
        try await fixture.model.refresh()
        #expect(fixture.model.providers.map(\.id) == ["clipboard", "emoji"])
        #expect(fixture.model.providers.map(\.version) == ["1", "2"])
        let calls = await fixture.gate.readCalls()
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.2.target == .notch && $0.2.tile == fixture.origin.tile })
        try await fixture.model.perform(providerID: "clipboard", actionID: "change")
        #expect(await fixture.gate.performed() == ["clipboard/change"])
        #expect(fixture.model.providers[0].snapshot.rows[0].value == "changed")
        await #expect(throws: (any Error).self) {
            try await fixture.model.perform(providerID: "emoji", actionID: "not-issued")
        }
        #expect(await fixture.gate.performed().count == 1)
        await fixture.model.stop()
        #expect(fixture.model.pendingCount == 0 && fixture.model.providers.isEmpty)
    }

    @Test func explicitPanelNavigationPreservesOriginAndRejectsLateVersionReplacement() async throws
    {
        let fixture = CompactCardFixture(widget: .codeStats, versions: ["codeStats": "1"])
        try await fixture.model.refresh()
        try await fixture.model.open(providerID: "codeStats")
        #expect(fixture.navigation.count == 1)
        #expect(fixture.navigation[0].0 == fixture.origin)
        #expect(fixture.navigation[0].1 == "codeStats" && fixture.navigation[0].2 == "1")
        fixture.replaceOnNavigation = true
        await #expect(throws: (any Error).self) {
            try await fixture.model.open(providerID: "codeStats")
        }
        await fixture.model.stop()
    }

    @Test func postNavigationRunsOnlyAfterFinalAdmissionAndExpectedRetirementDoesNotInvalidateAck()
        async throws
    {
        let fixture = CompactCardFixture(widget: .codeStats, versions: ["codeStats": "1"])
        var acknowledgements = 0
        fixture.postNavigation = { origin, provider, version in
            #expect(fixture.navigation.count == 1)
            #expect(origin == fixture.origin && provider == "codeStats" && version == "1")
            #expect(fixture.model.pendingCount == 0)
            acknowledgements += 1
            fixture.admitted = false
            fixture.model.invalidate()
        }
        try await fixture.model.open(providerID: "codeStats")
        #expect(acknowledgements == 1)
        fixture.admitted = true
        fixture.replaceOnNavigation = true
        await #expect(throws: (any Error).self) {
            try await fixture.model.open(providerID: "codeStats")
        }
        #expect(acknowledgements == 1)
        fixture.replaceOnNavigation = false
        fixture.failNavigation = true
        await #expect(throws: HostWindowNavigationError.routeRejected) {
            try await fixture.model.open(providerID: "codeStats")
        }
        #expect(acknowledgements == 1)
        await fixture.model.stop()
        await #expect(throws: (any Error).self) {
            try await fixture.model.open(providerID: "codeStats")
        }
        #expect(acknowledgements == 1)
    }

    @Test func duplicateOpenCannotConsumeAnotherPendingNavigationReceipt() async throws {
        let fixture = CompactCardFixture(widget: .github, versions: ["quinjet": "1"])
        var entered = false
        var resume: CheckedContinuation<Void, Never>?
        fixture.postNavigation = { _, _, _ in
            entered = true
            await withCheckedContinuation { resume = $0 }
        }
        let first = Task { try await fixture.model.open(providerID: "quinjet") }
        await fixture.wait { entered }
        await #expect(throws: HostNotchPanelError.capacityExceeded) {
            try await fixture.model.open(providerID: "quinjet")
        }
        #expect(fixture.navigation.count == 1)
        resume?.resume()
        try await first.value
        await fixture.model.stop()
    }

    @Test func hiddenOrStalePanelDoesNotFetchSnapshotsOrPerformActions() async throws {
        let fixture = CompactCardFixture(widget: .machines, versions: ["machines": "1"])
        fixture.admitted = false
        await #expect(throws: (any Error).self) { try await fixture.model.refresh() }
        #expect(await fixture.gate.readCalls().isEmpty)
        fixture.admitted = true
        try await fixture.model.refresh()
        fixture.admitted = false
        await #expect(throws: (any Error).self) {
            try await fixture.model.perform(providerID: "machines", actionID: "change")
        }
        await #expect(throws: (any Error).self) {
            try await fixture.model.open(providerID: "machines")
        }
        #expect(await fixture.gate.performed().isEmpty && fixture.navigation.isEmpty)
        await fixture.model.stop()
    }

    @Test func stopCancelsAndDrainsLateSnapshotWithoutPublishingItsContent() async throws {
        let fixture = CompactCardFixture(widget: .github, versions: ["quinjet": "1"])
        await fixture.gate.hold()
        let reading = Task { try await fixture.model.refresh() }
        for _ in 0..<100 {
            if await fixture.gate.started() { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fixture.gate.started())
        let stopping = Task { await fixture.model.stop() }
        await Task.yield()
        await fixture.gate.release()
        _ = try? await reading.value
        await stopping.value
        #expect(fixture.model.providers.isEmpty && fixture.model.pendingCount == 0)
        await #expect(throws: (any Error).self) { try await fixture.model.refresh() }
    }

    @Test func dedicatedOriginalBodiesAreNotReplacedBySharedCards() {
        for widget: SurfaceWidget in [
            .music, .calendar, .usage, .activity, .limits, .actions, .clocks,
        ] {
            #expect(!HostNotchCompactCardModel.supports(widget))
        }
        for widget: SurfaceWidget in [
            .agents, .focus, .codeStats, .databases, .machines, .github, .desk, .media,
            .ability("latex"),
        ] {
            #expect(HostNotchCompactCardModel.supports(widget))
        }
    }
}

private actor CompactCardGate {
    var held = false
    var waiting: CheckedContinuation<Void, Never>?
    var actions: [String] = []
    var calls: [(String, String, SurfaceSnapshotRequest)] = []
    func readCalls() -> [(String, String, SurfaceSnapshotRequest)] { calls }
    func started() -> Bool { waiting != nil }
    func hold() { held = true }
    func release() { held = false; waiting?.resume(); waiting = nil }
    func execute(_ id: String, _ command: String, _ payload: Data) async throws -> Data {
        if held { await withCheckedContinuation { waiting = $0 } }
        let request =
            command == "surface.perform"
            ? try SurfaceActionRequest.decode(payload, providerID: id).snapshot
            : try SurfaceSnapshotRequest.decode(payload, providerID: id)
        calls.append((id, command, request))
        var value = "original"
        if command == "surface.perform" {
            let action = try SurfaceActionRequest.decode(payload, providerID: id)
            actions.append(id + "/" + action.actionID)
            value = "changed"
        }
        let renderedValue = value
        return try await compactFixtureSnapshot(providerID: id, value: renderedValue)
    }
    func performed() -> [String] { actions }
}

@MainActor
private final class CompactCardFixture {
    let origin: HostNotchCompactOrigin
    var versions: [String: String]
    var admitted = true
    var replaceOnNavigation = false
    var failNavigation = false
    var postNavigation: HostNotchCompactCardModel.Navigate?
    var navigation: [(HostNotchCompactOrigin, String, String)] = []
    let gate = CompactCardGate()
    lazy var requests = makeRequests()
    private func makeRequests() -> SurfaceSnapshotClient {
        let capturedGate = gate
        return SurfaceSnapshotClient(activeVersions: { [self] in
            versions.merging(["notchShelf": "1"]) { first, _ in first }
        }) { id, command, data in
            try await capturedGate.execute(id, command, data)
        }
    }
    lazy var model = HostNotchCompactCardModel(
        origin: origin, requests: requests,
        admission: { [self] candidate in candidate == origin && admitted ? versions : nil },
        navigate: { [self] origin, id, version in
            navigation.append((origin, id, version))
            if failNavigation { throw HostWindowNavigationError.routeRejected }
            if replaceOnNavigation { versions[id] = "new" }
        },
        postNavigation: { [self] origin, provider, version in
            try await postNavigation?(origin, provider, version)
        })
    init(widget: SurfaceWidget, versions: [String: String], dense: Bool = false) {
        self.versions = versions
        var tile = SurfaceTile(widget)
        tile.dense = dense
        tile.accentHex = "336699"
        tile.sourceIDs = ["synthetic-source"]
        tile.metricColumns = 2
        tile.itemLimit = 3
        origin = .init(
            identity: .init(ownershipID: UUID(), generation: UUID()), displayID: 7,
            panelPresentationID: UUID(), cardPresentationID: UUID(), tile: tile)
    }
    func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

@MainActor
private func compactFixtureSnapshot(providerID: String, value: String) throws -> Data {
    try SurfaceSnapshot(
        providerID: providerID,
        rows: [
            .init(
                "row", sourceID: "synthetic-source", title: "Synthetic original item", value: value,
                actions: [.init("change", "Change", "checkmark")])
        ]
    ).encoded()
}

@MainActor
private func compactControls(_ node: NSObject, label: String, depth: Int = 0) -> [NSObject] {
    guard depth < 64 else { return [] }
    var result: [NSObject] = []
    if (node as AnyObject).accessibilityRole?() == .button,
        (node as AnyObject).accessibilityLabel?() == label
    {
        result.append(node)
    }
    for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
        result += compactControls(child, label: label, depth: depth + 1)
    }
    if let view = node as? NSView {
        for child in view.subviews {
            result += compactControls(child, label: label, depth: depth + 1)
        }
    }
    return Array(Dictionary(grouping: result, by: ObjectIdentifier.init).values.compactMap(\.first))
}
