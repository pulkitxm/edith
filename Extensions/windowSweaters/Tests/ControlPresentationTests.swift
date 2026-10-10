import EdithExtensionSupport
import Foundation
import Testing

@testable import WindowSweatersExtension

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
                ? "sample"
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
                ControlPresentationContract.stringKeys.contains(key) ? "sample" : true, forKey: key)
        }
        let packet = try ControlPresentationContract.snapshot(
            defaults: engine,
            state: ControlPresentationState(muted: true, cpu: 32, memory: 48))
        let model = ControlPresentation(client: nil, defaults: local) { operation, _ in
            #expect(operation == "windowSweaters.ui.read")
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
    @Test func ownedPreferenceWriteProtectsNewerEditsFromStaleReads() async throws {
        let engine = fixture()
        let local = fixture()
        let key = try #require(ControlPresentationContract.writable.sorted().first)
        let original: Any =
            ControlPresentationContract.stringKeys.contains(key)
            ? "original"
            : ControlPresentationContract.boolKeys.contains(key)
                ? NSNumber(value: false) : NSNumber(value: 1)
        let changed: Any =
            ControlPresentationContract.stringKeys.contains(key)
            ? "changed"
            : ControlPresentationContract.boolKeys.contains(key)
                ? NSNumber(value: true) : NSNumber(value: 2)
        engine.set(original, forKey: key)
        var reads = 0
        var writes = 0
        var pending: CheckedContinuation<Data, any Error>?
        let stale = try ControlPresentationContract.snapshot(
            defaults: engine, state: ControlPresentationState())
        let model = ControlPresentation(client: nil, defaults: local) { operation, payload in
            if operation == "windowSweaters.ui.read" {
                reads += 1
                if reads > 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
                return try ControlPresentationContract.snapshot(
                    defaults: engine, state: ControlPresentationState())
            }
            #expect(operation == "windowSweaters.ui.update")
            try ControlPresentationContract.update(payload, defaults: engine)
            writes += 1
            return Data("{}".utf8)
        }
        await model.refresh()
        let read = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        local.set(changed, forKey: key)
        model.changed()
        for _ in 0..<100 where writes == 0 { await Task.yield() }
        #expect(writes == 1)
        pending?.resume(returning: stale)
        await read.value
        #expect(
            NSDictionary(dictionary: [key: local.object(forKey: key) ?? NSNull()]).isEqual(to: [
                key: changed
            ]))
        #expect(
            NSDictionary(dictionary: [key: engine.object(forKey: key) ?? NSNull()]).isEqual(to: [
                key: changed
            ]))
        model.stop()
    }

    @Test func stopCancelsOwnedActionTask() async throws {
        let defaults = fixture()
        var began = false
        var cancelled = false
        let packet = try ControlPresentationContract.snapshot(
            defaults: defaults, state: ControlPresentationState())
        let model = ControlPresentation(client: nil, defaults: defaults) { operation, payload in
            if operation == "windowSweaters.ui.read" { return packet }
            #expect(operation == "windowSweaters.ui.action")
            let request = try JSONDecoder().decode(ControlPresentationAction.self, from: payload)
            #expect(request.action == "fixtureAction")
            began = true
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
            Issue.record("stopped action ran to completion")
            return Data("{}".utf8)
        }
        await model.refresh()
        model.perform("fixtureAction")
        for _ in 0..<100 where !began { await Task.yield() }
        #expect(began)
        model.stop()
        for _ in 0..<100 where !cancelled { await Task.yield() }
        #expect(cancelled)
        #expect(model.error == nil)
    }

    @Test func disabledPreferencesPersistAndReplayOnlyEditedKeysAfterEnable() async throws {
        let engine = fixture()
        let local = fixture()
        let key = try #require(ControlPresentationContract.writable.sorted().first)
        let initial: Any =
            ControlPresentationContract.stringKeys.contains(key)
            ? "original"
            : ControlPresentationContract.boolKeys.contains(key)
                ? NSNumber(value: false) : NSNumber(value: 1)
        let changed: Any =
            ControlPresentationContract.stringKeys.contains(key)
            ? "changed"
            : ControlPresentationContract.boolKeys.contains(key)
                ? NSNumber(value: true) : NSNumber(value: 2)
        local.set(initial, forKey: key)
        engine.set(initial, forKey: key)
        let disabled = ControlPresentation(client: nil, defaults: local)
        local.set(changed, forKey: key)
        disabled.changed()
        disabled.stop()
        var updates = 0
        func active() -> ControlPresentation {
            ControlPresentation(client: nil, defaults: local) { operation, payload in
                if operation == "windowSweaters.ui.update" {
                    let update = try JSONDecoder().decode(
                        ControlPreferenceUpdate.self, from: payload)
                    let values = try ControlPresentationContract.decode(
                        update.values, keys: ControlPresentationContract.writable)
                    #expect(Set(values.keys).union(update.removed) == [key])
                    try ControlPresentationContract.update(payload, defaults: engine)
                    updates += 1
                    return Data("{}".utf8)
                }
                #expect(operation == "windowSweaters.ui.read")
                return try ControlPresentationContract.snapshot(
                    defaults: engine, state: ControlPresentationState())
            }
        }
        let enabled = active()
        await enabled.refresh()
        #expect(enabled.ready)
        #expect(updates == 1)
        #expect(
            NSDictionary(dictionary: [key: engine.object(forKey: key) ?? NSNull()]).isEqual(to: [
                key: changed
            ]))
        enabled.stop()
        let reopened = active()
        await reopened.refresh()
        #expect(updates == 1)
        reopened.stop()
        let disabledAgain = ControlPresentation(client: nil, defaults: local)
        local.removeObject(forKey: key)
        disabledAgain.changed()
        disabledAgain.stop()
        let unset = active()
        await unset.refresh()
        #expect(updates == 2)
        #expect(engine.object(forKey: key) == nil)
        #expect(local.object(forKey: key) == nil)
        unset.stop()
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
