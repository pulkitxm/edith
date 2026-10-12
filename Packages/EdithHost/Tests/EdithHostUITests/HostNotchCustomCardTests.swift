import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import Foundation
import HostAccessibilityFixtureSupport
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostNotchCustomCardTests {
    @Test func customCardParserPreservesWholeSavedIdentityAndRejectsForeignAndStaleAdmission()
        throws
    {
        let fixture = HostNotchStateFixture()
        for widget: SurfaceWidget in [.agents, .focus] {
            let provider = widget == .agents ? "herdr" : "attention"
            var tile = SurfaceTile(widget)
            tile.instanceID = "synthetic-custom-instance"
            tile.title = "Synthetic custom card"
            tile.focusMinutes = 47
            tile.includeSubagents = false
            tile.sourceIDs = ["synthetic-source"]
            tile.hiddenFields = ["quiet", "model"]
            let slot = fixture.slot(provider: provider, tile: tile)
            let state = fixture.state(slots: [slot])
            let admission = fixture.admission(
                active: ["notchShelf": "1.0.0", provider: "1.0.0"], layout: .init(tiles: [tile]))
            let decoded = try HostNotchPanelState.decode(JSONEncoder().encode(state))
            try decoded.validate(admission)
            #expect(decoded.slots.first?.tile == tile)
            #expect(slot.anchorProvider(activeVersions: admission.activeVersions) == provider)
            let request = try slot.request(presentationID: slot.id)
            #expect(request.extensionID == provider && request.presentationID == slot.id)
            #expect(request.section == "surface.card" && request.surface?.tile == tile)
            for foreign in ["music", provider == "herdr" ? "attention" : "herdr"] {
                #expect(throws: HostNotchPanelError.invalidState) {
                    try fixture.state(slots: [fixture.slot(provider: foreign, tile: tile)])
                        .validate(
                            admission)
                }
            }
            #expect(throws: HostNotchPanelError.unavailableProvider) {
                try decoded.validate(
                    fixture.admission(
                        active: ["notchShelf": "1.0.0", provider: "2.0.0"], layout: admission.layout
                    ))
            }
            #expect(throws: HostNotchPanelError.invalidState) {
                try fixture.state(slots: [slot, fixture.slot(provider: provider, tile: tile)])
                    .validate(
                        admission)
            }
            var changed = tile
            changed.includeSubagents.toggle()
            #expect(throws: HostNotchPanelError.invalidState) {
                try decoded.validate(
                    fixture.admission(
                        active: admission.activeVersions, layout: .init(tiles: [changed])))
            }
            var hidden = admission
            hidden.hiddenWidgets = [widget]
            #expect(throws: HostNotchPanelError.unavailableProvider) {
                try decoded.validate(hidden)
            }
            #expect(throws: HostNotchPanelError.invalidState) {
                try fixture.state(phase: .collapsed, slots: [slot]).validate(admission)
            }
            let foreignPresentation = HostNotchPanelAdmission(
                ownershipID: fixture.ownershipID, notchVersion: "1.0.0", presentationID: UUID(),
                display: fixture.display, previousRevision: nil,
                activeVersions: admission.activeVersions,
                layout: admission.layout)
            #expect(throws: HostNotchPanelError.staleState) {
                try decoded.validate(foreignPresentation)
            }
        }
    }

    @Test func originalCustomFocusAndAgentControlsRenderNeverVisibleAndUseIssuedActions()
        async throws
    {
        _ = TestWindowHost.application
        let accessibility = try HostAccessibilityFixture.enable()
        defer {
            for error in accessibility.restore() { Issue.record(error) }
        }
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for widget: SurfaceWidget in [.agents, .focus] {
            for (width, zoom, scheme, dense) in [
                (280.0, 1.0, ColorScheme.light, true), (560.0, 1.0, .dark, false),
                (420.0, 1.5, .light, false), (700.0, 1.5, .dark, true),
            ] {
                UIScale.apply(zoom)
                let fixture = CustomCardFixture(widget: widget, dense: dense)
                try await fixture.model.refresh()
                let host = NSHostingView(
                    rootView: HostNotchCompactCard(
                        model: fixture.model, layout: fixture.layout, measured: { _ in }
                    ).environment(\.colorScheme, scheme).environment(
                        \.automaticViewActionsEnabled, false
                    )
                    .transaction { $0.animation = nil })
                host.frame = .init(x: 0, y: 0, width: width, height: 900)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentView = host
                for _ in 0..<8 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
                #expect(host.fittingSize.height.isFinite && host.fittingSize.height > 40)
                let action = widget == .focus ? "Start focus" : "Allow once"
                let button = try #require(customCardControls(host, label: action).first)
                #expect((button as AnyObject).accessibilityPerformPress?() == true)
                await fixture.wait {
                    fixture.model.providers.first?.snapshot.actions.first?.id
                        == (widget == .focus ? "focus.finish" : "open")
                        && fixture.model.pendingCount == 0
                }
                for _ in 0..<100 {
                    if await fixture.gate.actions().count == 1 { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(
                    await fixture.gate.actions() == [
                        widget == .focus ? "focus.start.47" : "approval.allow-once"
                    ])
                if widget == .focus {
                    for _ in 0..<8 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let finish = try #require(customCardControls(host, label: "Finish").first)
                    #expect((finish as AnyObject).accessibilityPerformPress?() == true)
                    for _ in 0..<100 {
                        if await fixture.gate.actions().count == 2 { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    #expect(await fixture.gate.actions() == ["focus.start.47", "focus.finish"])
                }
                let openLabel = "Open " + widget.title
                #expect(customCardControls(host, label: openLabel).count == 1)
                let open = try #require(customCardControls(host, label: openLabel).first)
                #expect((open as AnyObject).accessibilityPerformPress?() == true)
                await fixture.wait { fixture.navigation.count == 1 }
                #expect(fixture.navigation.first?.0 == fixture.origin)
                #expect(fixture.navigation.first?.1 == widget.destination)
                #expect(fixture.navigation.first?.2 == "1.0.0")
                #expect(
                    await fixture.gate.requests().allSatisfy {
                        $0.tile == fixture.origin.tile && $0.target == .notch
                    })
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                await fixture.model.stop()
                window.contentView = nil
                #expect(fixture.model.providers.isEmpty && fixture.model.pendingCount == 0)
            }
        }
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func currentCustomCardPrivacyVersionAndOwnedPresentationGateRevokesLateDataAndActions()
        async throws
    {
        for widget: SurfaceWidget in [.agents, .focus] {
            let fixture = CustomCardFixture(widget: widget)
            try await fixture.model.refresh()
            let action = widget == .focus ? "focus.start.47" : "approval.allow-once"
            await #expect(throws: (any Error).self) {
                try await fixture.model.perform(
                    providerID: fixture.provider, actionID: "not-issued")
            }
            fixture.privacy = [
                "active": "1", widget == .focus ? "blurAttention" : "blurAgents": "1",
            ]
            await #expect(throws: (any Error).self) {
                try await fixture.model.perform(providerID: fixture.provider, actionID: action)
            }
            await #expect(throws: (any Error).self) {
                try await fixture.model.open(providerID: fixture.provider)
            }
            #expect(await fixture.gate.actions().isEmpty && fixture.navigation.isEmpty)
            fixture.privacy = [:]
            await fixture.gate.hold()
            let read = Task { try await fixture.model.refresh() }
            for _ in 0..<100 {
                if await fixture.gate.waiting() { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await fixture.gate.waiting())
            fixture.versions[fixture.provider] = "2.0.0"
            fixture.admitted = false
            let stopping = Task { await fixture.model.stop() }
            await Task.yield()
            await fixture.gate.release()
            _ = try? await read.value
            await stopping.value
            #expect(fixture.model.pendingCount == 0 && fixture.model.providers.isEmpty)
            await #expect(throws: (any Error).self) { try await fixture.model.refresh() }
            #expect(fixture.requests.pendingCount == 0)
        }
    }

    @Test func originalInheritedCanvasPaddingAndCornersStayOutsideImmutableSavedTile() async throws
    {
        _ = TestWindowHost.application
        let fixture = CustomCardFixture(widget: .focus)
        try await fixture.model.refresh()
        let tile = fixture.origin.tile
        #expect(tile.paddingOverride == nil && tile.cornerOverride == nil)
        var heights: [Double] = []
        for padding in [14.0, 34.0] {
            var layout = fixture.layout
            layout.padding = padding
            layout.cornerRadius = padding == 14 ? 12 : 26
            let presentation = SurfacePresentation(tile: tile, layout: layout)
            #expect(
                presentation.padding == padding && presentation.cornerRadius == layout.cornerRadius)
            let host = NSHostingView(
                rootView: HostNotchCompactCard(
                    model: fixture.model, layout: layout, measured: { _ in }
                )
                .environment(\.automaticViewActionsEnabled, false).transaction {
                    $0.animation = nil
                })
            host.frame = .init(x: 0, y: 0, width: 400, height: 600)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            heights.append(host.fittingSize.height)
            #expect(!window.isVisible && fixture.model.origin.tile == tile)
            window.contentView = nil
        }
        #expect(heights[1] > heights[0] + 30)
        await fixture.model.stop()
    }
}

private actor CustomCardGate {
    private var focus = false
    private var approval = true
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var performed: [String] = []
    private var calls: [SurfaceSnapshotRequest] = []
    func actions() -> [String] { performed }
    func requests() -> [SurfaceSnapshotRequest] { calls }
    func hold() { held = true }
    func waiting() -> Bool { continuation != nil }
    func release() {
        held = false
        continuation?.resume()
        continuation = nil
    }
    func execute(_ provider: String, _ command: String, _ payload: Data) async throws -> Data {
        if held { await withCheckedContinuation { continuation = $0 } }
        let request =
            command == "surface.perform"
            ? try SurfaceActionRequest.decode(payload, providerID: provider).snapshot
            : try SurfaceSnapshotRequest.decode(payload, providerID: provider)
        calls.append(request)
        return try await SurfaceCommandService.execute(
            providerID: provider, command: command, payload: payload,
            snapshot: { tile in await self.snapshot(provider: provider, tile: tile) },
            perform: { try await self.perform($0) }, privacyValues: { [:] })
    }
    private func perform(_ action: String) throws {
        switch action {
        case "focus.start.47":
            guard !focus else { throw ExtensionPeerError.invalidRequest }
            focus = true
        case "focus.finish":
            guard focus else { throw ExtensionPeerError.invalidRequest }
            focus = false
        case "approval.allow-once", "approval.deny":
            guard approval else { throw ExtensionPeerError.invalidRequest }
            approval = false
        case "session.open", "open": break
        default: throw ExtensionPeerError.invalidRequest
        }
        performed.append(action)
    }
    private func snapshot(provider: String, tile: SurfaceTile) -> SurfaceSnapshot {
        if tile.widget == .focus {
            return .init(
                providerID: provider,
                metrics: [
                    .init("remaining", focus ? "Remaining" : "Focus", focus ? "12m" : "47 min")
                ],
                rows: focus
                    ? [
                        .init(
                            "synthetic-focus", sourceID: "focus", title: "Synthetic deep work",
                            field: "session")
                    ] : [],
                actions: [
                    .init(
                        focus ? "focus.finish" : "focus.start.47", focus ? "Finish" : "Start focus",
                        focus ? "stop.fill" : "play.fill")
                ])
        }
        var rows: [SurfaceDataRow] = [
            .init(
                "synthetic-session", sourceID: "synthetic-source", title: "Synthetic worker",
                detail: "Synthetic project", value: "Working", icon: "terminal", field: "sessions",
                actions: [.init("session.open", "Open", "macwindow", field: "sessions")])
        ]
        if approval {
            rows.insert(
                .init(
                    "synthetic-approval", sourceID: "synthetic-source",
                    title: "Synthetic tool request",
                    value: "30s", icon: "hand.raised.fill", field: "approvals",
                    actions: [
                        .init("approval.deny", "Deny", "xmark", field: "approvals"),
                        .init("approval.allow-once", "Allow once", "checkmark", field: "approvals"),
                    ]), at: 0)
        }
        return .init(
            providerID: provider,
            metrics: [
                .init("running", "Working", "1"),
                .init("waiting", "Needs you", approval ? "1" : "0"),
                .init("quiet", "No signal", "0"),
            ], rows: rows, actions: [.init("open", "Open Herdr", "macwindow")])
    }
}

@MainActor private final class CustomCardFixture {
    let origin: HostNotchCompactOrigin
    let provider: String
    let layout: SurfaceLayout
    let gate = CustomCardGate()
    var versions: [String: String]
    var privacy: [String: String] = [:]
    var admitted = true
    var navigation: [(HostNotchCompactOrigin, String, String)] = []
    lazy var requests = makeRequests()
    private func makeRequests() -> SurfaceSnapshotClient {
        let capturedGate = gate
        return SurfaceSnapshotClient(activeVersions: { [self] in versions }) {
            try await capturedGate.execute($0, $1, $2)
        }
    }
    lazy var model = HostNotchCompactCardModel(
        origin: origin, requests: requests,
        admission: { [self] candidate in
            guard admitted, candidate == origin,
                !SurfacePrivacyState.hides(candidate.tile.widget, values: privacy),
                versions["notchShelf"] == "1.0.0", let version = versions[provider]
            else { return nil }
            return [provider: version]
        },
        navigate: { [self] candidate, provider, version in
            navigation.append((candidate, provider, version))
        })
    init(widget: SurfaceWidget, dense: Bool = false) {
        provider = widget == .focus ? "attention" : "herdr"
        versions = ["notchShelf": "1.0.0", provider: "1.0.0"]
        var tile = SurfaceTile(widget)
        tile.instanceID = "synthetic-custom-card"
        tile.title = "Synthetic " + widget.title
        tile.focusMinutes = 47
        tile.includeSubagents = false
        tile.dense = dense
        tile.sourceIDs = widget == .focus ? nil : ["synthetic-source"]
        tile.itemLimit = 3
        tile.metricColumns = 2
        origin = .init(
            identity: .init(ownershipID: UUID(), generation: UUID()), displayID: 7,
            panelPresentationID: UUID(), cardPresentationID: UUID(), tile: tile)
        layout = .init(tiles: [tile])
    }
    func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor private func customCardControls(_ node: NSObject, label: String, depth: Int = 0)
    -> [NSObject]
{
    guard depth < 64 else { return [] }
    var result: [NSObject] = []
    if (node as AnyObject).accessibilityRole?() == .button,
        (node as AnyObject).accessibilityLabel?() == label
    {
        result.append(node)
    }
    for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
        result += customCardControls(child, label: label, depth: depth + 1)
    }
    if let view = node as? NSView {
        for child in view.subviews {
            result += customCardControls(child, label: label, depth: depth + 1)
        }
    }
    return Array(Dictionary(grouping: result, by: ObjectIdentifier.init).values.compactMap(\.first))
}

@MainActor @Suite(.serialized) struct HostAccessibilityFixtureTests {
    @Test(arguments: [[false, false], [false, true], [true, false], [true, true]])
    func snapshotsBothAttributesBeforeMutationAndRestoresExactValues(originals: [Bool]) throws {
        let memory = MemoryAccess(originals: originals)
        let fixture = try HostAccessibilityFixture(access: memory.access)
        #expect(
            Array(memory.operations.prefix(2))
                == HostAccessibilityFixture.attributes.map { "copy:" + $0 })
        #expect(memory.values.values.allSatisfy { CFEqual($0, kCFBooleanTrue) })
        #expect(fixture.restore().isEmpty)
        #expect(memory.matchesOriginals)
        #expect(Array(memory.writes.suffix(2)) == HostAccessibilityFixture.attributes.reversed())
        let count = memory.operations.count
        #expect(fixture.restore().isEmpty)
        #expect(memory.operations.count == count)
    }

    @Test(arguments: [1, 2])
    func failedSnapshotNeverMutatesEitherAttribute(copy: Int) {
        let memory = MemoryAccess()
        memory.failedCopies = [copy]
        #expect(throws: InjectedFailure.copy(copy)) {
            try HostAccessibilityFixture(access: memory.access)
        }
        #expect(memory.writes.isEmpty && memory.matchesOriginals)
    }

    @Test(arguments: [1, 2])
    func failingSetAfterMutationRestoresEveryAttemptedAttribute(set: Int) throws {
        let memory = MemoryAccess()
        memory.failedAfterMutation = [set]
        do {
            _ = try HostAccessibilityFixture(access: memory.access)
            Issue.record("Expected the injected set failure")
        } catch let error as HostAccessibilityFixture.ActivationFailure {
            #expect(error.primary as? InjectedFailure == .set(set))
            #expect(error.restoration.isEmpty)
        }
        #expect(memory.matchesOriginals)
        #expect(
            Array(memory.writes.suffix(set))
                == Array(HostAccessibilityFixture.attributes.prefix(set).reversed()))
    }

    @Test func successfulSetWithWrongReadbackFailsAndRollsBack() throws {
        let memory = MemoryAccess()
        memory.ignoredSets = [1]
        do {
            _ = try HostAccessibilityFixture(access: memory.access)
            Issue.record("Expected a failed enable readback")
        } catch let error as HostAccessibilityFixture.ActivationFailure {
            guard
                case .mismatch(let operation, let attribute) = error.primary
                    as? HostAccessibilityFixture.Failure
            else {
                Issue.record("Expected the enable mismatch error")
                return
            }
            #expect(operation == "enable" && attribute == HostAccessibilityFixture.attributes[0])
            #expect(error.restoration.isEmpty)
        }
        #expect(memory.matchesOriginals)
    }

    @Test func failedEnableReadbackRestoresTheAttemptedAttribute() throws {
        let memory = MemoryAccess()
        memory.failedCopies = [3]
        do {
            _ = try HostAccessibilityFixture(access: memory.access)
            Issue.record("Expected the injected copy failure")
        } catch let error as HostAccessibilityFixture.ActivationFailure {
            #expect(error.primary as? InjectedFailure == .copy(3))
            #expect(error.restoration.isEmpty)
        }
        #expect(memory.matchesOriginals)
    }

    @Test func restorationContinuesAfterFailureAndRetriesOnlyUnrestoredValues() throws {
        let memory = MemoryAccess()
        let fixture = try HostAccessibilityFixture(access: memory.access)
        memory.failedSets = [3]
        let failures = fixture.restore()
        #expect(failures.count == 1 && failures.first as? InjectedFailure == .set(3))
        #expect(CFEqual(memory.values[HostAccessibilityFixture.attributes[0]], kCFBooleanFalse))
        #expect(CFEqual(memory.values[HostAccessibilityFixture.attributes[1]], kCFBooleanTrue))
        #expect(memory.writes.count == 4)
        #expect(fixture.restore().isEmpty && memory.matchesOriginals)
        #expect(
            memory.writes.count == 5 && memory.writes.last == HostAccessibilityFixture.attributes[1]
        )
        #expect(fixture.restore().isEmpty && memory.writes.count == 5)
    }

    @Test func restorationReadbackMismatchIsReportedAndRetainedForRetry() throws {
        let memory = MemoryAccess()
        let fixture = try HostAccessibilityFixture(access: memory.access)
        memory.ignoredSets = [3]
        let failures = fixture.restore()
        #expect(failures.count == 1)
        guard
            case .mismatch(let operation, let attribute) = failures.first
                as? HostAccessibilityFixture.Failure
        else {
            Issue.record("Expected the restore mismatch error")
            return
        }
        #expect(operation == "restore" && attribute == HostAccessibilityFixture.attributes[1])
        #expect(fixture.restore().isEmpty && memory.matchesOriginals)
        #expect(memory.writes.count == 5)
    }

    @Test func activationFailureIncludesRollbackFailureWithoutSkippingOtherRestorations() throws {
        let memory = MemoryAccess()
        memory.failedAfterMutation = [2]
        memory.failedSets = [3]
        do {
            _ = try HostAccessibilityFixture(access: memory.access)
            Issue.record("Expected activation and rollback failures")
        } catch let error as HostAccessibilityFixture.ActivationFailure {
            #expect(error.primary as? InjectedFailure == .set(2))
            #expect(
                error.restoration.count == 1
                    && error.restoration.first as? InjectedFailure == .set(3))
        }
        #expect(memory.writes.count == 4)
        #expect(CFEqual(memory.values[HostAccessibilityFixture.attributes[0]], kCFBooleanFalse))
        #expect(CFEqual(memory.values[HostAccessibilityFixture.attributes[1]], kCFBooleanTrue))
    }

    @Test func throwingBodyStillRestoresItsOwnedFixture() throws {
        let memory = MemoryAccess()
        #expect(throws: InjectedFailure.body) {
            let fixture = try HostAccessibilityFixture(access: memory.access)
            defer { #expect(fixture.restore().isEmpty) }
            throw InjectedFailure.body
        }
        #expect(memory.matchesOriginals)
    }

    private enum InjectedFailure: Error, Equatable {
        case copy(Int)
        case set(Int)
        case body
    }

    @MainActor private final class MemoryAccess {
        var values: [String: CFTypeRef]
        let originals: [String: CFTypeRef]
        var operations: [String] = []
        var writes: [String] = []
        var failedCopies: Set<Int> = []
        var failedSets: Set<Int> = []
        var failedAfterMutation: Set<Int> = []
        var ignoredSets: Set<Int> = []
        private var copies = 0
        private var sets = 0

        init(originals: [Bool] = [false, false]) {
            values = Dictionary(
                uniqueKeysWithValues: zip(
                    HostAccessibilityFixture.attributes,
                    originals.map { $0 ? kCFBooleanTrue! : kCFBooleanFalse! }))
            self.originals = values
        }

        var matchesOriginals: Bool {
            originals.allSatisfy { CFEqual(values[$0.key], $0.value) }
        }

        var access: HostAccessibilityFixture.Access {
            .init(
                copy: { attribute in
                    self.copies += 1
                    self.operations.append("copy:" + attribute)
                    if self.failedCopies.contains(self.copies) {
                        throw InjectedFailure.copy(self.copies)
                    }
                    return try #require(self.values[attribute])
                },
                set: { attribute, value in
                    self.sets += 1
                    self.operations.append("set:" + attribute)
                    self.writes.append(attribute)
                    if self.failedSets.contains(self.sets) { throw InjectedFailure.set(self.sets) }
                    if !self.ignoredSets.contains(self.sets) { self.values[attribute] = value }
                    if self.failedAfterMutation.contains(self.sets) {
                        throw InjectedFailure.set(self.sets)
                    }
                })
        }
    }
}
