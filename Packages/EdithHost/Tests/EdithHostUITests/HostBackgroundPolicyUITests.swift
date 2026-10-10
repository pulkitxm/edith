import AppKit
import EdithExtensionUI
import EdithHostCore
import Foundation
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostBackgroundPolicyUITests {
    @Test func checkedReadAndSetUseTheActualReturnedScalarWithoutOptimisticState() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        #expect(model.value == nil)
        let read = Task { await model.refresh() }
        await fixture.started(1)
        #expect(model.value == nil && model.load.isRunning)
        fixture.finish(0, try scalar(false))
        await read.value
        #expect(model.value == false && model.current)
        let write = Task { await model.set(true) }
        await fixture.started(2)
        #expect(fixture.requested == [true])
        #expect(model.value == false && model.saving)
        await model.refresh()
        #expect(fixture.calls.count == 2)
        fixture.finish(1, try scalar(false))
        await write.value
        #expect(model.value == false && !model.saving)
        let acknowledged = Task { await model.set(true) }
        await fixture.started(3)
        #expect(model.value == false)
        fixture.finish(2, try scalar(true))
        await acknowledged.value
        #expect(model.value == true && model.current)
    }

    @Test(arguments: [
        "core:42|herdr:2:77", "core:41|herdr:3:77", "core:41|herdr:2:78", "core:41", "",
    ])
    func changedCoreVersionOwnerOrOfflineCannotAcceptReadOrWrite(identity: String) async throws {
        let fixture = Fixture()
        let model = fixture.model()
        let read = Task { await model.refresh() }
        await fixture.started(1)
        fixture.owner = identity.isEmpty ? nil : .init(identity: identity, processIdentifier: 41)
        fixture.finish(0, try scalar(true))
        await read.value
        #expect(model.value == nil && !model.current && !model.load.isRunning)
        fixture.owner = Fixture.originalOwner
        let reload = Task { await model.refresh() }
        await fixture.started(2)
        fixture.finish(1, try scalar(false))
        await reload.value
        let write = Task { await model.set(true) }
        await fixture.started(3)
        fixture.owner = identity.isEmpty ? nil : .init(identity: identity, processIdentifier: 41)
        #expect(model.value == nil)
        fixture.finish(2, try scalar(true))
        await write.value
        #expect(model.value == nil && !model.current && !model.saving && model.failure == nil)
        await model.set(false)
        #expect(fixture.requested == [true])
    }

    @Test func wrongReturnedPIDIsRejectedForReadAndWrite() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        let first = Task { await model.refresh() }
        await fixture.started(1)
        fixture.finish(0, try scalar(true, pid: 42))
        await first.value
        #expect(model.value == nil && model.failure != nil)
        let second = Task { await model.refresh() }
        await fixture.started(2)
        fixture.finish(1, try scalar(false))
        await second.value
        let write = Task { await model.set(true) }
        await fixture.started(3)
        fixture.finish(2, try scalar(true, pid: 42))
        await write.value
        #expect(model.value == nil && !model.current && model.failure != nil && !model.saving)
    }

    @Test func newerReadWinsAndCancellationRetiresPendingReadAndWrite() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        let first = Task { await model.refresh() }
        await fixture.started(1)
        let second = Task { await model.refresh() }
        await fixture.started(2)
        fixture.finish(1, try scalar(true))
        await second.value
        fixture.finish(0, try scalar(false))
        await first.value
        #expect(model.value == true)
        let read = Task { await model.refresh() }
        await fixture.started(3)
        read.cancel()
        fixture.finish(2, try scalar(false))
        await read.value
        #expect(model.value == true && !model.load.isRunning)
        let write = Task { await model.set(false) }
        await fixture.started(4)
        model.cancel()
        write.cancel()
        fixture.finish(3, try scalar(false))
        await write.value
        #expect(model.value == nil && !model.saving && model.failure == nil)
        let reload = Task { await model.refresh() }
        await fixture.started(5)
        fixture.finish(4, try scalar(true))
        await reload.value
        let cancelled = Task { await model.set(false) }
        cancelled.cancel()
        await cancelled.value
        #expect(fixture.requested == [false])
        #expect(model.value == true)
    }

    @Test func retiredWriteCannotReplaceARefreshedPolicyOrPublishLateError() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        let read = Task { await model.refresh() }
        await fixture.started(1)
        fixture.finish(0, try scalar(false))
        await read.value
        let old = Task { await model.set(true) }
        await fixture.started(2)
        model.cancel()
        let latest = Task { await model.refresh() }
        await fixture.started(3)
        fixture.finish(2, try scalar(false))
        await latest.value
        fixture.fail(1)
        await old.value
        #expect(model.value == false && model.failure == nil && model.current)
    }

    @Test func offlineAndFailuresStayActionableWithoutInventingSavedState() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        fixture.owner = nil
        await model.refresh()
        await model.set(true)
        #expect(fixture.calls.isEmpty && model.value == nil && model.failure != nil)
        fixture.owner = Fixture.originalOwner
        let read = Task { await model.refresh() }
        await fixture.started(1)
        fixture.fail(0)
        await read.value
        #expect(model.value == nil && model.failure != nil && !model.load.isRunning)
        let retry = Task { await model.refresh() }
        await fixture.started(2)
        fixture.finish(1, try scalar(false))
        await retry.value
        let write = Task { await model.set(true) }
        await fixture.started(3)
        fixture.fail(2)
        await write.value
        #expect(model.value == false && model.failure != nil && !model.saving)
    }

    private func scalar(_ value: Bool, pid: Int32 = 41) throws -> HostCoreBackgroundPolicy {
        try JSONDecoder().decode(
            HostCoreBackgroundPolicy.self,
            from: JSONSerialization.data(
                withJSONObject: ["processIdentifier": pid, "pauseAmbientOnBattery": value]))
    }

    @MainActor private final class Fixture {
        static let originalOwner = HostBackgroundPolicyOwner(
            identity: "core:41|herdr:2:77", processIdentifier: 41)
        var owner: HostBackgroundPolicyOwner? = originalOwner
        var requested: [Bool] = []
        var calls: [CheckedContinuation<HostCoreBackgroundPolicy, any Error>] = []
        private var signals: [(Int, CheckedContinuation<Void, Never>)] = []

        func model() -> HostBackgroundPolicyModel {
            .init(
                environment: .init(
                    owner: { self.owner }, read: { try await self.wait() },
                    set: { value in
                        self.requested.append(value)
                        return try await self.wait()
                    }))
        }

        func wait() async throws -> HostCoreBackgroundPolicy {
            try await withCheckedThrowingContinuation { continuation in
                calls.append(continuation)
                let ready = signals.filter { $0.0 <= calls.count }
                signals.removeAll { $0.0 <= calls.count }
                ready.forEach { $0.1.resume() }
            }
        }

        func started(_ count: Int) async {
            if calls.count >= count { return }
            await withCheckedContinuation { signals.append((count, $0)) }
        }

        func finish(_ index: Int, _ value: HostCoreBackgroundPolicy) {
            calls[index].resume(returning: value)
        }

        func fail(_ index: Int) {
            calls[index].resume(throwing: CocoaError(.fileReadUnknown))
        }
    }
}
