import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrSettingsTests {
    @Test func settingsFacadeUsesFixedOperationsAndDoesNotApplyStaleReplies() async throws {
        var pending: CheckedContinuation<Data, Error>?
        let model = HerdrSettingsModel { operation, payload in
            #expect(operation == "herdr.settings.read" && payload == Data("{}".utf8))
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let read = Task { await model.read() }
        while pending == nil { await Task.yield() }
        model.shutdown()
        pending?.resume(returning: try AgentPayload.encode(HerdrAttentionSettings(blocked: false)))
        await read.value
        #expect(model.settings.blocked && !model.loading && model.error == nil)
    }

    @Test func invalidBoundsAreRejectedAndFailedSaveRetainsPreviouslyLoadedSettings() async throws {
        var calls = 0
        let model = HerdrSettingsModel { operation, payload in
            calls += 1
            if calls == 1 {
                #expect(operation == "herdr.settings.read")
                return try AgentPayload.encode(
                    HerdrAttentionSettings(stuck: true, stuckMinutes: 15))
            }
            #expect(operation == "herdr.settings.save")
            let saved = try AgentPayload.decode(HerdrAttentionSettings.self, from: payload)
            #expect(saved.stuckMinutes == 120)
            throw ExtensionPeerError.unavailable
        }
        await model.read()
        model.update { $0.stuckMinutes = 300 }
        while calls < 2 || model.loading { await Task.yield() }
        #expect(model.settings.stuckMinutes == 15 && model.error != nil)
        let invalid = HerdrSettingsModel { _, _ in
            try AgentPayload.encode(HerdrAttentionSettings(stuckMinutes: 121))
        }
        await invalid.read()
        #expect(invalid.error != nil && invalid.settings.stuckMinutes == 10)
        model.shutdown()
        invalid.shutdown()
    }

    @Test func engineSettingsRejectInjectedFieldsTypesBoundsAndDisabledOwner() async throws {
        let suite = "herdr.settings.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { HerdrWorkOwnership.enable() }
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }),
            defaults: defaults, automaticActions: false)
        let initial = try AgentPayload.decode(
            HerdrAttentionSettings.self,
            from: await worker.execute("herdr.settings.read", payload: Data("{}".utf8)))
        #expect(initial.blocked && initial.finished && initial.errors && initial.stuckMinutes == 10)
        let settings = HerdrAttentionSettings(
            blocked: false, finished: false, errors: false,
            stuck: true, openDiff: true, stuckMinutes: 20, monitoring: true)
        let saved = try AgentPayload.decode(
            HerdrAttentionSettings.self,
            from: await worker.execute(
                "herdr.settings.save", payload: AgentPayload.encode(settings)))
        #expect(saved == settings && worker.activity.stuckMinutes == 20)
        let object = try #require(
            try JSONSerialization.jsonObject(with: AgentPayload.encode(settings)) as? [String: Any])
        for (key, value) in [
            ("path", "/tmp/mock" as Any), ("stuckMinutes", 1 as Any), ("stuckMinutes", true as Any),
            ("blocked", 1 as Any),
        ] {
            var invalid = object
            invalid[key] = value
            await #expect(throws: ExtensionPeerError.self) {
                try await worker.execute(
                    "herdr.settings.save", payload: JSONSerialization.data(withJSONObject: invalid))
            }
        }
        #expect(HerdrAttentionSettings(defaults: defaults) == settings)
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("herdr.settings.read", payload: Data("{}".utf8))
        }
    }

    @Test func originalSessionsSettingsUseOwnedCollectorsAndFixedGuideServices() async throws {
        defer { HerdrWorkOwnership.enable() }
        let cases: [([HerdrHostSnapshot], HerdrSessionCheck)] = [
            ([], .init(installed: 0, sessions: 0)),
            (
                [
                    .init(
                        id: "local", name: "Synthetic Mac", isLocal: true,
                        herdrPresent: true, reachable: true, agents: [])
                ], .init(installed: 1, sessions: 0)
            ),
            (
                [
                    .init(
                        id: "local", name: "Synthetic Mac", isLocal: true,
                        herdrPresent: true, reachable: true,
                        agents: [
                            .make(
                                machineID: "local",
                                machineName: "Synthetic Mac", machineIsLocal: true, sshTarget: nil,
                                session: "fixture", pane: "first", kind: "Synthetic tool",
                                status: .working,
                                title: "Synthetic session", workspace: "Synthetic space",
                                cwd: "/tmp/fixture")
                        ])
                ],
                .init(installed: 1, sessions: 1)
            ),
        ]
        for (hosts, expected) in cases {
            let defaults = HerdrUIDefaults()
            var guideOpens = 0
            let worker = HerdrWorker(
                openGuide: { guideOpens += 1 },
                store: HerdrStore(defaults: defaults, machinesProvider: { [] }), defaults: defaults,
                automaticActions: false,
                inventory: .init(collect: { scope in
                    if case .all = scope {
                    } else {
                        Issue.record("Expected original all-machine check")
                    }
                    return hosts
                }))
            let facade = HerdrUIClient { try await worker.execute($0, payload: $1) }
            let model = HerdrSessionSettingsModel(client: facade)
            model.checkSessions()
            for _ in 0..<300 {
                if !model.checking { break }; try await Task.sleep(for: .milliseconds(1))
            }
            #expect(model.result == expected && model.error == nil)
            #expect(model.result?.message == expected.message)
            model.openGuide()
            for _ in 0..<300 {
                if guideOpens == 1 { break }; try await Task.sleep(for: .milliseconds(1))
            }
            #expect(guideOpens == 1)
            for operation in ["herdr.settings.sessions", "herdr.settings.guide"] {
                await #expect(throws: ExtensionPeerError.self) {
                    try await worker.execute(
                        operation, payload: Data("{\"path\":\"/tmp/injected\"}".utf8))
                }
            }
            model.shutdown()
            model.checkSessions(); model.openGuide()
            #expect(!model.checking && guideOpens == 1)
            await worker.shutdown()
            await #expect(throws: ExtensionPeerError.self) {
                try await worker.execute("herdr.settings.guide", payload: Data("{}".utf8))
            }
        }
    }

    @Test func cancelledOriginalSessionCheckCannotPublishALateCollectorResult() async throws {
        var pending: CheckedContinuation<Data, Error>?
        let client = HerdrUIClient { operation, _ in
            #expect(operation == "herdr.settings.sessions")
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let model = HerdrSessionSettingsModel(client: client)
        model.checkSessions()
        while pending == nil { await Task.yield() }
        model.shutdown()
        pending?.resume(
            returning: try JSONEncoder().encode(HerdrSessionCheck(installed: 1, sessions: 1)))
        for _ in 0..<10 { await Task.yield() }
        #expect(model.result == nil && !model.checking && model.error == nil)
    }

    @Test func exactOriginalSettingsSectionsRenderProviderAndSessionsFormsOffscreen() async throws {
        defer { HerdrWorkOwnership.enable() }
        #expect(HerdrSettingsSection(rawValue: "agentActivity") == .agentActivity)
        #expect(HerdrSettingsSection(rawValue: "extension") == .extensionSettings)
        #expect(HerdrSettingsSection(rawValue: "backgroundAgent") == .backgroundAgent)
        #expect(HerdrSettingsSection(rawValue: "injected") == nil)
        _ = TestWindowHost.application
        let defaults = HerdrUIDefaults()
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }),
            defaults: defaults, automaticActions: false)
        let facade = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let store = HerdrStore(uiClient: facade)
        let monitor = AgentActivityMonitor(defaults: store.uiDefaults, uiClient: facade)
        store.uiActivity = monitor
        let state = try #require(try facade.state(await facade.perform("herdr.ui.read")))
        store.adoptUI(state)
        let sessions = HerdrSessionSettingsModel(client: facade)
        let accessibility = try HerdrAccessibilityFixture.enable()
        let previousZoom = UIScale.current
        defer {
            sessions.shutdown(); store.stopRendering()
            UIScale.apply(previousZoom)
            for error in accessibility.restore() { Issue.record(error) }
        }
        for zoom in [1.0, 1.4] {
            UIScale.apply(zoom)
            for width in [520.0, 1100.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let pages: [(AnyView, [String])] = [
                        (
                            AnyView(HerdrExtensionSettingsPage(model: sessions)),
                            ["Check sessions", "Open Herdr", "Open setup guide"]
                        ),
                        (
                            AnyView(HerdrActivitySettingsPage(store: store, monitor: monitor)),
                            [
                                "Configure a project instead of global hooks",
                                "Discover agents in local and remote Herdr terminals",
                                "Inspect blocked agents and stalled progress",
                            ]
                        ),
                    ]
                    for (page, labels) in pages {
                        let host = NSHostingView(
                            rootView:
                                page
                                .environment(\.automaticViewActionsEnabled, false)
                                .environment(\.colorScheme, scheme)
                                .environment(\.compactLayout, width < 600))
                        host.frame = .init(x: 0, y: 0, width: width, height: 1600)
                        let window = TestWindowHost.window(contentRect: host.frame)
                        window.isReleasedWhenClosed = false
                        window.contentView = host
                        defer { window.contentView = nil; window.close() }
                        for _ in 0..<4 {
                            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        for label in labels {
                            let control = try #require(find(host, label: label), "Missing \(label)")
                            let frame = (control as AnyObject).accessibilityFrame?() ?? .zero
                            #expect(frame.width > 0 && frame.height > 0)
                            #expect(
                                frame.minX >= window.frame.minX && frame.maxX <= window.frame.maxX)
                        }
                        #expect(!TestWindowHost.isExposedOnDesktop(window))
                    }
                }
            }
        }
        await worker.shutdown()
        await store.shutdown(); await monitor.shutdown()
    }

    @Test func notificationSettingsRenderAtCompactRegularWidthsZoomAndColorSchemes() async throws {
        _ = TestWindowHost.application
        let model = HerdrSettingsModel { _, _ in
            try AgentPayload.encode(HerdrAttentionSettings(stuck: true))
        }
        await model.read()
        let accessibility = try HerdrAccessibilityFixture.enable()
        let previousZoom = UIScale.current
        defer {
            UIScale.apply(previousZoom)
            for error in accessibility.restore() { Issue.record(error) }
            model.shutdown()
        }
        for zoom in [1.0, 1.5] {
            UIScale.apply(zoom)
            for width in [520.0, 1100.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: HerdrSettingsPage(model: model)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.colorScheme, scheme)
                            .environment(\.compactLayout, width < 600))
                    host.frame = .init(x: 0, y: 0, width: width, height: 1000)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.isReleasedWhenClosed = false
                    window.contentView = host

                    defer { window.contentView = nil; window.close() }
                    for _ in 0..<4 {
                        window.layoutIfNeeded()
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    for label in [
                        "Needs approval or an answer", "Finishes its work", "Hits an error",
                        "Looks stuck", "Open the diff when an agent finishes",
                    ] {
                        let control = try #require(
                            find(host, label: label),
                            "Missing \(label) at width \(width), zoom \(zoom), scheme \(scheme)")
                        let frame = (control as AnyObject).accessibilityFrame?() ?? .zero
                        #expect(frame.width > 0 && frame.height > 0)
                        #expect(
                            frame.minX >= window.frame.minX && frame.maxX <= window.frame.maxX,
                            "\(label) at width \(width), zoom \(zoom), scheme \(scheme), frame \(frame), window \(window.frame)"
                        )
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

@MainActor @Suite(.serialized) struct HerdrAccessibilityFixtureTests {
    private static let attributes = ["synthetic-first", "synthetic-second"]

    @Test(
        arguments: [
            [false, false], [false, true], [true, false], [true, true],
            [nil, nil], [nil, false], [nil, true], [false, nil], [true, nil],
        ] as [[Bool?]])
    func snapshotsBothAttributesBeforeMutationAndRestoresExactValues(originals: [Bool?]) throws {
        let memory = MemoryAccess(originals: originals)
        let fixture = try HerdrAccessibilityFixture(
            attributes: Self.attributes, access: memory.access)
        #expect(
            Array(memory.operations.prefix(2))
                == Self.attributes.map { "copy:" + $0 })
        #expect(memory.values.values.allSatisfy { CFEqual($0, kCFBooleanTrue) })
        #expect(fixture.restore().isEmpty)
        #expect(memory.matchesOriginals)
        #expect(Array(memory.writes.suffix(2)) == Self.attributes.reversed())
        let count = memory.operations.count
        #expect(fixture.restore().isEmpty)
        #expect(memory.operations.count == count)
    }

    @Test func restoresOriginalObjectWithoutReplacingItsIdentity() throws {
        let memory = MemoryAccess(originals: [nil, false])
        let original = NSMutableString(string: "synthetic attribute value")
        memory.values[Self.attributes[0]] = original
        let fixture = try HerdrAccessibilityFixture(
            attributes: Self.attributes, access: memory.access)
        #expect(fixture.restore().isEmpty)
        #expect(memory.values[Self.attributes[0]] === original)
        #expect(Array(memory.writes.suffix(2)) == Self.attributes.reversed())
    }

    @Test(arguments: [1, 2])
    func failedSnapshotNeverMutatesEitherAttribute(copy: Int) {
        let memory = MemoryAccess()
        memory.failedCopies = [copy]
        #expect(throws: InjectedFailure.copy(copy)) {
            try HerdrAccessibilityFixture(attributes: Self.attributes, access: memory.access)
        }
        #expect(memory.writes.isEmpty && memory.matchesOriginals)
    }

    @Test(arguments: [1, 2])
    func failingSetAfterMutationRestoresEveryAttemptedAttribute(set: Int) throws {
        let memory = MemoryAccess()
        memory.failedAfterMutation = [set]
        do {
            _ = try HerdrAccessibilityFixture(attributes: Self.attributes, access: memory.access)
            Issue.record("Expected the injected set failure")
        } catch let error as HerdrAccessibilityFixture.ActivationFailure {
            #expect(error.primary as? InjectedFailure == .set(set))
            #expect(error.restoration.isEmpty)
        }
        #expect(memory.matchesOriginals)
        #expect(
            Array(memory.writes.suffix(set))
                == Array(Self.attributes.prefix(set).reversed()))
    }

    @Test func successfulSetWithWrongReadbackFailsAndRollsBack() throws {
        let memory = MemoryAccess()
        memory.ignoredSets = [1]
        do {
            _ = try HerdrAccessibilityFixture(attributes: Self.attributes, access: memory.access)
            Issue.record("Expected a failed enable readback")
        } catch let error as HerdrAccessibilityFixture.ActivationFailure {
            guard
                case .mismatch(let operation, let attribute) = error.primary
                    as? HerdrAccessibilityFixture.Failure
            else {
                Issue.record("Expected the enable mismatch error")
                return
            }
            #expect(operation == "enable" && attribute == Self.attributes[0])
            #expect(error.restoration.isEmpty)
        }
        #expect(memory.matchesOriginals)
    }

    @Test func failedEnableReadbackRestoresTheAttemptedAttribute() throws {
        let memory = MemoryAccess()
        memory.failedCopies = [3]
        do {
            _ = try HerdrAccessibilityFixture(attributes: Self.attributes, access: memory.access)
            Issue.record("Expected the injected copy failure")
        } catch let error as HerdrAccessibilityFixture.ActivationFailure {
            #expect(error.primary as? InjectedFailure == .copy(3))
            #expect(error.restoration.isEmpty)
        }
        #expect(memory.matchesOriginals)
    }

    @Test func restorationContinuesAfterFailureAndRetriesOnlyUnrestoredValues() throws {
        let memory = MemoryAccess()
        let fixture = try HerdrAccessibilityFixture(
            attributes: Self.attributes, access: memory.access)
        memory.failedSets = [3]
        let failures = fixture.restore()
        #expect(failures.count == 1 && failures.first as? InjectedFailure == .set(3))
        #expect(CFEqual(memory.values[Self.attributes[0]], kCFBooleanFalse))
        #expect(CFEqual(memory.values[Self.attributes[1]], kCFBooleanTrue))
        #expect(memory.writes.count == 4)
        #expect(fixture.restore().isEmpty && memory.matchesOriginals)
        #expect(
            memory.writes.count == 5
                && memory.writes.last == Self.attributes[1]
        )
        #expect(fixture.restore().isEmpty && memory.writes.count == 5)
    }

    @Test func restorationReadbackMismatchIsReportedAndRetainedForRetry() throws {
        let memory = MemoryAccess()
        let fixture = try HerdrAccessibilityFixture(
            attributes: Self.attributes, access: memory.access)
        memory.ignoredSets = [3]
        let failures = fixture.restore()
        #expect(failures.count == 1)
        guard
            case .mismatch(let operation, let attribute) = failures.first
                as? HerdrAccessibilityFixture.Failure
        else {
            Issue.record("Expected the restore mismatch error")
            return
        }
        #expect(operation == "restore" && attribute == Self.attributes[1])
        #expect(fixture.restore().isEmpty && memory.matchesOriginals)
        #expect(memory.writes.count == 5)
    }

    @Test func failedRestorationReadbackRetriesOnlyTheUnverifiedNilSnapshot() throws {
        let memory = MemoryAccess(originals: [false, nil])
        let fixture = try HerdrAccessibilityFixture(
            attributes: Self.attributes, access: memory.access)
        memory.failedCopies = [5]
        let failures = fixture.restore()
        #expect(failures.count == 1 && failures.first as? InjectedFailure == .copy(5))
        #expect(memory.matchesOriginals)
        #expect(Array(memory.writes.suffix(2)) == Self.attributes.reversed())
        #expect(fixture.restore().isEmpty && memory.matchesOriginals)
        #expect(
            memory.writes.count == 5
                && memory.writes.last == Self.attributes[1]
        )
        #expect(fixture.restore().isEmpty && memory.writes.count == 5)
    }

    @Test func nilRestorationMismatchIsReportedWithoutReplacingNilWithFalse() throws {
        let memory = MemoryAccess(originals: [nil, nil])
        let fixture = try HerdrAccessibilityFixture(
            attributes: Self.attributes, access: memory.access)
        memory.ignoredSets = [3]
        let failures = fixture.restore()
        #expect(failures.count == 1)
        guard
            case .mismatch(let operation, let attribute) = failures.first
                as? HerdrAccessibilityFixture.Failure
        else {
            Issue.record("Expected the nil restore mismatch error")
            return
        }
        #expect(operation == "restore" && attribute == Self.attributes[1])
        #expect(memory.values[Self.attributes[0]] == nil)
        #expect(CFEqual(memory.values[Self.attributes[1]], kCFBooleanTrue))
        #expect(fixture.restore().isEmpty && memory.matchesOriginals)
        #expect(memory.values.isEmpty && memory.writes.count == 5)
    }

    @Test func activationFailureIncludesRollbackFailureWithoutSkippingOtherRestorations() throws {
        let memory = MemoryAccess()
        memory.failedAfterMutation = [2]
        memory.failedSets = [3]
        do {
            _ = try HerdrAccessibilityFixture(attributes: Self.attributes, access: memory.access)
            Issue.record("Expected activation and rollback failures")
        } catch let error as HerdrAccessibilityFixture.ActivationFailure {
            #expect(error.primary as? InjectedFailure == .set(2))
            #expect(
                error.restoration.count == 1
                    && error.restoration.first as? InjectedFailure == .set(3))
        }
        #expect(memory.writes.count == 4)
        #expect(CFEqual(memory.values[Self.attributes[0]], kCFBooleanFalse))
        #expect(CFEqual(memory.values[Self.attributes[1]], kCFBooleanTrue))
    }

    @Test func throwingBodyStillRestoresItsOwnedFixture() throws {
        let memory = MemoryAccess()
        #expect(throws: InjectedFailure.body) {
            let fixture = try HerdrAccessibilityFixture(
                attributes: Self.attributes, access: memory.access)
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

        init(originals: [Bool?] = [false, false]) {
            values = [:]
            for (attribute, value) in zip(HerdrAccessibilityFixtureTests.attributes, originals) {
                if let value { values[attribute] = value ? kCFBooleanTrue : kCFBooleanFalse }
            }
            self.originals = values
        }

        var matchesOriginals: Bool {
            HerdrAccessibilityFixtureTests.attributes.allSatisfy {
                switch (values[$0], originals[$0]) {
                case (nil, nil): return true
                case (let value?, let original?): return CFEqual(value, original)
                default: return false
                }
            }
        }

        var access: HerdrAccessibilityFixture.Access {
            .init(
                copy: { attribute in
                    self.copies += 1
                    self.operations.append("copy:" + attribute)
                    if self.failedCopies.contains(self.copies) {
                        throw InjectedFailure.copy(self.copies)
                    }
                    return self.values[attribute]
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
