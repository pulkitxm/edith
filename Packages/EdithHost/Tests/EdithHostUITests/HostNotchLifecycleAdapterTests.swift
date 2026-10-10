import AppKit
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchLifecycleAdapterTests {
    @Test func enabledVersionStartsOriginalDisplaySceneAndUnchangedRefreshReusesIt() async throws {
        let fixture = NotchLifecycleFixture()
        let adapter = fixture.adapter()
        try await adapter.refresh()
        await fixture.settle()
        #expect(fixture.created == 1 && fixture.sceneCreated == 1)
        #expect(adapter.panelCount == 1)
        #expect(fixture.attach?.displays == fixture.screens.map(\.request))
        try await adapter.refresh()
        #expect(fixture.created == 1 && fixture.sceneCreated == 1)
        fixture.environment.activeVersions = [:]
        try await adapter.refresh()
        #expect(fixture.operations.suffix(2) == ["notch.panel.scene.stop", "notch.panel.detach"])
        #expect(fixture.released)
        #expect(adapter.panelCount == 0 && adapter.pendingCleanupCount == 0)
        try await adapter.stop()
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func withdrawnVersionRetainsCleanupAndExplicitRetryNeverReopensScenes() async throws {
        let fixture = NotchLifecycleFixture()
        let adapter = fixture.adapter()
        try await adapter.refresh()
        await fixture.settle()
        fixture.environment.activeVersions = [:]
        fixture.failDetach = true
        await #expect(throws: HostWorkerError.rejected) { try await adapter.refresh() }
        #expect(adapter.pendingCleanupCount == 1 && adapter.failure != nil)
        #expect(fixture.created == 1 && fixture.released)
        fixture.failDetach = false
        try await adapter.stop()
        #expect(adapter.pendingCleanupCount == 0 && adapter.failure == nil)
        fixture.environment.activeVersions = ["notchShelf": "1.0.0"]
        try await adapter.refresh()
        #expect(fixture.created == 1)
    }

    @Test func explicitPanelAssociationSurvivesFailedSceneDrainAndRejectsStaleOrigins() async throws
    {
        let fixture = NotchLifecycleFixture()
        let adapter = fixture.adapter()
        try await adapter.refresh()
        await fixture.settle()
        let id = fixture.screens[0].presentationID
        #expect(adapter.window(for: id) === fixture.associations.values.first)
        #expect(adapter.window(for: UUID()) == nil)
        #expect(fixture.associations.count == 1)
        fixture.environment.activeVersions = [:]
        fixture.failSceneStop = true
        await #expect(throws: HostWorkerError.rejected) { try await adapter.refresh() }
        #expect(adapter.window(for: id) == nil)
        #expect(fixture.associations.count == 1 && fixture.removed.isEmpty)
        fixture.failSceneStop = false
        try await adapter.stop()
        #expect(fixture.associations.isEmpty && fixture.removed.count == 1)
        try await adapter.stop()
        #expect(fixture.removed.count == 1)
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func explicitOwningWorkspaceChangeDrainsOldAssociationBeforeBindingReplacement()
        async throws
    {
        let fixture = NotchLifecycleFixture()
        let adapter = fixture.adapter()
        try await adapter.refresh()
        await fixture.settle()
        let oldToken = try #require(fixture.associations.keys.first)
        fixture.rejectAssociation = true
        await #expect(throws: HostWorkerError.rejected) {
            try await adapter.owningWorkspaceChanged()
        }
        #expect(fixture.removed == [oldToken] && fixture.associations.isEmpty)
        #expect(
            fixture.sceneCreated == 1
                && adapter.window(for: fixture.screens[0].presentationID) == nil)
        fixture.rejectAssociation = false
        try await adapter.owningWorkspaceChanged()
        for _ in 0..<100 {
            if fixture.sceneCreated == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.sceneCreated == 2 && fixture.associations.count == 1)
        #expect(fixture.associations[oldToken] == nil)
        #expect(
            adapter.window(for: fixture.screens[0].presentationID)
                === fixture.associations.values.first)
        try await adapter.stop()
        try await adapter.owningWorkspaceChanged()
        #expect(fixture.removed.count == 2 && fixture.sceneCreated == 2)
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func overlappingRefreshAndWorkspaceChangeKeepOnlyOnePanelAssociation() async throws {
        let fixture = NotchLifecycleFixture()
        let adapter = fixture.adapter()
        try await adapter.refresh()
        async let first: Void = adapter.refresh()
        async let second: Void = adapter.refresh()
        async let changed: Void = adapter.owningWorkspaceChanged()
        _ = try await (first, second, changed)
        #expect(fixture.associations.count == 1 && adapter.panelCount == 1)
        #expect(fixture.created == 2 && fixture.removed.count == 1)
        try await adapter.stop()
        #expect(fixture.associations.isEmpty && fixture.removed.count == 2)
    }

    @Test func unavailableOwningWorkspaceNeverCreatesOrPresentsAnUnassociatedScene() async throws {
        let fixture = NotchLifecycleFixture()
        fixture.rejectAssociation = true
        let adapter = fixture.adapter()
        await #expect(throws: HostWorkerError.rejected) { try await adapter.refresh() }
        #expect(fixture.sceneCreated == 0 && fixture.associations.isEmpty)
        #expect(adapter.panelCount == 0 && adapter.pendingCleanupCount == 0)
        #expect(fixture.operations.last == "notch.panel.detach")
        try await adapter.stop()
    }

    @Test func disabledNotchDoesNotConstructCoordinatorOrNativePanels() async throws {
        let fixture = NotchLifecycleFixture()
        fixture.environment.activeVersions = [:]
        let adapter = fixture.adapter()
        try await adapter.refresh()
        #expect(fixture.created == 0 && fixture.sceneCreated == 0)
        #expect(fixture.operations.isEmpty)
        try await adapter.stop()
    }
}

@MainActor
private final class NotchLifecycleFixture {
    var environment = HostNotchPanelEnvironment(
        activeVersions: ["notchShelf": "1.0.0"], layout: .init(tiles: []))
    let screens: [HostNotchPanelScreen]
    var created = 0
    var sceneCreated = 0
    var operations: [String] = []
    var attach: HostNotchPanelAttach?
    var current: HostNotchPanelBatch?
    var released = false
    var failDetach = false
    var failSceneStop = false
    var rejectAssociation = false
    var associations: [UUID: NSWindow] = [:]
    var removed: [UUID] = []

    init() {
        _ = TestWindowHost.application
        screens = [
            .init(
                display: .init(
                    id: 7, frame: CGRect(x: -1024, y: 0, width: 1024, height: 768),
                    collapsedSize: CGSize(width: 150, height: 28)), isBuiltin: false)
        ]
    }

    func adapter() -> HostNotchLifecycleAdapter {
        HostNotchLifecycleAdapter(
            environment: { [self] in environment }, screens: { [self] in screens }
        ) { [self] _ in
            created += 1
            return HostNotchPanelCoordinator(
                invoke: invoke, environment: { [self] in environment },
                association: .init(
                    associate: { [self] panel in
                        if rejectAssociation { throw HostWorkerError.rejected }
                        let token = UUID()
                        associations[token] = panel
                        return token
                    },
                    remove: { [self] token in
                        #expect(associations.removeValue(forKey: token) != nil)
                        removed.append(token)
                    }),
                create: { [self] request in
                    sceneCreated += 1
                    let controller = NSViewController()
                    controller.view = NSView()
                    return HostNotchSceneLease(
                        request: request, controller: controller, update: { _, _, _ in },
                        release: { [self] in released = true })
                }, present: { panel in #expect(!panel.isVisible) })
        }
    }

    func settle() async {
        for _ in 0..<100 {
            if sceneCreated == 1 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(sceneCreated == 1)
    }

    func invoke(_ operation: String, payload: Data, timeout: Double) async throws -> Data {
        operations.append(operation)
        switch operation {
        case "notch.panel.attach":
            let request = try JSONDecoder().decode(HostNotchPanelAttach.self, from: payload)
            attach = request
            current = HostNotchPanelBatch(
                identity: .init(ownershipID: request.ownershipID, generation: UUID()), revision: 1,
                states: request.displays.map { screen in
                    .init(
                        contractVersion: 1, ownershipID: request.ownershipID,
                        version: request.version, revision: 1, displayID: screen.displayID,
                        presentationID: screen.presentationID, phase: .expanded, activeTab: "home",
                        shapeWidth: 580, shapeHeight: 400, visible: true, acceptsPointer: true,
                        acceptsKeyFocus: false, slots: [])
                })
            return try JSONEncoder().encode(current)
        case "notch.panel.wait":
            try await Task.sleep(for: .seconds(25))
            return try JSONEncoder().encode(current)
        case "notch.panel.scene.stop":
            #expect(released)
            if failSceneStop { throw HostWorkerError.rejected }
            let request = try JSONDecoder().decode(HostNotchPanelSceneStop.self, from: payload)
            #expect(request.displayID == 7 && request.presentationID == screens[0].presentationID)
        case "notch.panel.detach":
            #expect(sceneCreated == 0 || released)
            if failDetach { throw HostWorkerError.rejected }
        default: throw HostWorkerError.rejected
        }
        return Data("{}".utf8)
    }
}
