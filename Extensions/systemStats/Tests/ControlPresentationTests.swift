import EdithExtensionSupport
import Foundation
import Testing

@testable import SystemStatsExtension

@MainActor @Suite(.serialized) struct ControlPresentationTests {
    private func fixture() -> UserDefaults {
        UserDefaults(suiteName: "edith.controls.fixture." + UUID().uuidString)!
    }

    @Test func updateIsScopedAndAtomic() throws {
        let defaults = fixture()
        let before = defaults.dictionaryRepresentation()
        let key = ControlPresentationContract.writable.sorted().first
        let invalid = try JSONEncoder().encode(
            ControlPreferenceUpdate(
                values: ControlPresentationContract.encode(["foreignAccount": "secret"]),
                removed: []))
        #expect(throws: (any Error).self) {
            try ControlPresentationContract.update(invalid, defaults: defaults)
        }
        #expect((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: before))
        if let key {
            let value: Any =
                ControlPresentationContract.stringKeys.contains(key)
                ? (key == AppStorageKeys.MenuBar.statsColorMode ? "auto" : "12AB34")
                : ControlPresentationContract.boolKeys.contains(key)
                    ? NSNumber(value: true) : NSNumber(value: 1)
            let update = try JSONEncoder().encode(
                ControlPreferenceUpdate(
                    values: ControlPresentationContract.encode([key: value]), removed: []))
            try ControlPresentationContract.update(update, defaults: defaults)
            #expect(defaults.object(forKey: key) != nil)
            let wrong = try JSONEncoder().encode(
                ControlPreferenceUpdate(
                    values: ControlPresentationContract.encode([key: ["nested": "unexpected"]]),
                    removed: []))
            #expect(throws: (any Error).self) {
                try ControlPresentationContract.update(wrong, defaults: defaults)
            }
            let remove = try JSONEncoder().encode(
                ControlPreferenceUpdate(
                    values: ControlPresentationContract.encode([:]), removed: [key]))
            try ControlPresentationContract.update(remove, defaults: defaults)
            #expect(defaults.object(forKey: key) == nil)
        }
        for key in ControlPresentationContract.readable.subtracting(
            ControlPresentationContract.writable)
        {
            let update = try JSONEncoder().encode(
                ControlPreferenceUpdate(
                    values: ControlPresentationContract.encode([key: true]), removed: []))
            #expect(throws: (any Error).self) {
                try ControlPresentationContract.update(update, defaults: defaults)
            }
        }
    }

    @Test func stoppedPresentationRejectsLateSnapshotAndNewActions() async throws {
        let defaults = fixture()
        var continuation: CheckedContinuation<Data, any Error>?
        var calls = 0
        let model = ControlPresentation(client: nil, defaults: defaults) { _, _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let read = Task { await model.refresh() }
        while continuation == nil { await Task.yield() }
        model.stop()
        continuation?.resume(
            returning: try ControlPresentationContract.snapshot(
                defaults: defaults,
                state: ControlPresentationState(muted: true, cpu: 80, memory: 75)))
        await read.value
        #expect(!model.ready)
        #expect(!model.state.muted)
        model.perform("foreign")
        await model.refresh()
        #expect(calls == 1)
    }

    @Test func readonlyModeDoesNotInvokeEngineOrConstructServices() async {
        let model = ControlPresentation(client: nil, defaults: fixture())
        #expect(model.ready)
        #expect(!model.active)
        model.start()
        model.changed()
        model.perform("pick")
        #expect(model.error == nil)
        model.stop()
    }

    @Test func engineSnapshotAdoptsOwnedPreferences() async throws {
        let engine = fixture()
        let local = fixture()
        if let key = ControlPresentationContract.readable.sorted().first {
            engine.set(
                ControlPresentationContract.stringKeys.contains(key)
                    ? (key == AppStorageKeys.MenuBar.statsColorMode ? "auto" : "12AB34") : true,
                forKey: key)
        }
        let packet = try ControlPresentationContract.snapshot(
            defaults: engine,
            state: ControlPresentationState(muted: true, cpu: 32, memory: 48))
        let model = ControlPresentation(client: nil, defaults: local) { operation, _ in
            #expect(operation == "systemStats.ui.read")
            return packet
        }
        await model.refresh()
        #expect(model.ready)
        #expect(model.state.muted)
        #expect(model.state.cpu == 32)
        for key in ControlPresentationContract.readable {
            #expect(
                NSDictionary(dictionary: ["value": local.object(forKey: key) ?? NSNull()])
                    .isEqual(to: ["value": engine.object(forKey: key) ?? NSNull()]))
        }
        model.stop()
    }
    @Test func checkedPreferencesRejectOutOfRangeNumbersAndBooleanTypeConfusion() throws {
        let defaults = fixture()
        for (key, range) in ControlPresentationContract.ranges {
            for value in [range.lowerBound - 1, range.upperBound + 1] {
                let payload = try JSONEncoder().encode(
                    ControlPreferenceUpdate(
                        values: ControlPresentationContract.encode([key: value]), removed: []))
                #expect(throws: (any Error).self) {
                    try ControlPresentationContract.update(payload, defaults: defaults)
                }
                #expect(defaults.object(forKey: key) == nil)
            }
        }
        for key in ControlPresentationContract.boolKeys {
            let payload = try JSONEncoder().encode(
                ControlPreferenceUpdate(
                    values: ControlPresentationContract.encode([key: 1]), removed: []))
            #expect(throws: (any Error).self) {
                try ControlPresentationContract.update(payload, defaults: defaults)
            }
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test func sharedLoadingRetainsContentAndRejectsCancelledRefresh() async throws {
        let defaults = fixture()
        var reads = 0
        var pending: CheckedContinuation<Data, any Error>?
        let packet = try ControlPresentationContract.snapshot(
            defaults: defaults, state: ControlPresentationState(muted: true))
        let model = ControlPresentation(client: nil, defaults: defaults) { _, _ in
            reads += 1
            if reads > 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return packet
        }
        await model.refresh()
        #expect(model.load.hasContent)
        let refresh = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        #expect(model.load.isRefreshing)
        #expect(model.load.state == .content)
        model.load.cancel()
        pending?.resume(
            returning: try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState(muted: false)))
        await refresh.value
        #expect(model.state.muted)
        #expect(model.load.hasContent)
        model.stop()
    }

    @Test func failedInitialLoadExposesRecoveryAndRestoresOriginalContent() async throws {
        let defaults = fixture()
        var fail = true
        let model = ControlPresentation(client: nil, defaults: defaults) { _, _ in
            if fail { throw ExtensionPeerError.unavailable }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        await model.refresh()
        #expect(model.load.state == .error)
        #expect(!model.ready)
        #expect(model.error != nil)
        fail = false
        await model.refresh()
        #expect(model.ready && model.error == nil)
        #expect(model.load.state == .content)
        model.stop()
    }

}
