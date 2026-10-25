import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostMusicSlotsTests {
    @Test func boundedVersionedStateRejectsConflictingAndMalformedSlotAdmission() throws {
        let valid = HostMusicSlotState(version: "1.0.0", footer: true, sidebar: false)
        #expect(
            try HostMusicSlotState.decode(JSONEncoder().encode(valid), version: "1.0.0") == valid)
        for data in [
            Data(), Data(repeating: 120, count: 4097), Data("{}".utf8),
            try JSONEncoder().encode(
                HostMusicSlotState(version: "2.0.0", footer: true, sidebar: false)),
            try JSONEncoder().encode(
                HostMusicSlotState(version: "1.0.0", footer: true, sidebar: true)),
        ] {
            #expect(throws: (any Error).self) {
                try HostMusicSlotState.decode(data, version: "1.0.0")
            }
        }
    }

    @Test func noReadStartsForHiddenUninstalledDisabledSuiteOrPresenterMaskedMusic() async throws {
        let fixture = MusicSlotsFixture()
        let slots = fixture.slots()
        let window = UUID()
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        slots.invalidate()
        #expect(fixture.calls == 0)
        slots.setVisible(window, visible: true)
        slots.synchronize(version: nil, mediaEnabled: true, hidden: false)
        slots.synchronize(version: "1.0.0", mediaEnabled: false, hidden: false)
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: true)
        await settle { slots.pendingTaskCount == 0 }
        #expect(fixture.calls == 0)
        #expect(!slots.footer && !slots.sidebar)
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        await settle { slots.footer }
        #expect(fixture.calls == 1)
        #expect(fixture.payloads == [Data("{}".utf8)])
        await slots.stop()
    }

    @Test func multipleVisibleWindowsShareOneReadUntilLastWindowHides() async throws {
        let fixture = MusicSlotsFixture()
        let slots = fixture.slots()
        let first = UUID(); let second = UUID()
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        slots.setVisible(first, visible: true)
        slots.setVisible(second, visible: true)
        await settle { slots.footer && slots.pendingTaskCount == 0 }
        #expect(fixture.calls == 1)
        slots.setVisible(first, visible: false)
        #expect(slots.footer)
        #expect(fixture.calls == 1)
        slots.setVisible(second, visible: false)
        #expect(!slots.footer)
        slots.invalidate()
        #expect(fixture.calls == 1)
        await slots.stop()
    }

    @Test func invalidationsCoalesceAndNeverRunConcurrentReadsOrBackgroundPolling() async throws {
        let fixture = MusicSlotsFixture()
        let gate = MusicSlotsGate()
        fixture.gate = gate
        let slots = fixture.slots()
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        slots.setVisible(UUID(), visible: true)
        await settle { gate.waiting }
        for _ in 0..<100 { slots.invalidate() }
        #expect(fixture.calls == 1)
        gate.release()
        await settle { fixture.calls == 2 && slots.pendingTaskCount == 0 }
        try await Task.sleep(for: .milliseconds(25))
        #expect(fixture.calls == 2)
        #expect(fixture.maximumConcurrentReads == 1)
        await slots.stop()
    }

    @Test func cancelledOldVersionCannotReviveAndNewVersionWaitsForOwnedDrain() async throws {
        let fixture = MusicSlotsFixture()
        fixture.responses = [
            try JSONEncoder().encode(
                HostMusicSlotState(version: "1.0.0", footer: true, sidebar: false)),
            try JSONEncoder().encode(
                HostMusicSlotState(version: "2.0.0", footer: false, sidebar: true)),
        ]
        let gate = MusicSlotsGate()
        fixture.gate = gate
        let slots = fixture.slots()
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        slots.setVisible(UUID(), visible: true)
        await settle { gate.waiting }
        slots.synchronize(version: "2.0.0", mediaEnabled: true, hidden: false)
        #expect(!slots.footer && !slots.sidebar)
        #expect(slots.pendingTaskCount == 1)
        #expect(fixture.calls == 1)
        gate.release()
        await settle { slots.sidebar && slots.pendingTaskCount == 0 }
        #expect(!slots.footer)
        #expect(fixture.maximumConcurrentReads == 1)
        #expect(slots.state?.version == "2.0.0")
        await slots.stop()
    }

    @Test func hiddenWindowCancelsLateReplyAndStopWaitsForEveryOwnedRead() async throws {
        let fixture = MusicSlotsFixture()
        let gate = MusicSlotsGate()
        fixture.gate = gate
        let slots = fixture.slots()
        let window = UUID()
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        slots.setVisible(window, visible: true)
        await settle { gate.waiting }
        slots.setVisible(window, visible: false)
        #expect(!slots.footer)
        #expect(slots.pendingTaskCount == 1)
        var stopped = false
        let stop = Task {
            await slots.stop(); stopped = true
        }
        await Task.yield()
        #expect(!stopped)
        gate.release()
        await stop.value
        #expect(stopped)
        #expect(slots.pendingTaskCount == 0)
        #expect(slots.state == nil)
        #expect(fixture.activeReads == 0)
    }

    @Test func refreshFailureKeepsOnlyCurrentOwnedCacheUntilPrivacyWithdrawsIt() async throws {
        let fixture = MusicSlotsFixture()
        let slots = fixture.slots()
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        slots.setVisible(UUID(), visible: true)
        await settle { slots.footer && slots.pendingTaskCount == 0 }
        fixture.responses = [Data("{}".utf8)]
        slots.invalidate()
        await settle { slots.failure != nil }
        #expect(slots.footer)
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: true)
        #expect(!slots.footer && !slots.sidebar)
        #expect(slots.state == nil)
        #expect(slots.failure == nil)
        await slots.stop()
    }

    @Test func controlOnlyNotificationReadsAuthenticatedStateOnlyWhileVisible() async throws {
        let fixture = MusicSlotsFixture()
        let slots = fixture.slots()
        let window = UUID()
        slots.synchronize(version: "1.0.0", mediaEnabled: true, hidden: false)
        slots.setVisible(window, visible: true)
        await settle { slots.footer && slots.pendingTaskCount == 0 }
        DistributedNotificationCenter.default().postNotificationName(
            .init(fixture.namespace + ".musicHostSlots"), object: nil, userInfo: nil,
            deliverImmediately: true)
        await settle { fixture.calls == 2 && slots.pendingTaskCount == 0 }
        slots.setVisible(window, visible: false)
        DistributedNotificationCenter.default().postNotificationName(
            .init(fixture.namespace + ".musicHostSlots"), object: nil, userInfo: nil,
            deliverImmediately: true)
        try await Task.sleep(for: .milliseconds(25))
        #expect(fixture.calls == 2)
        await slots.stop()
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class MusicSlotsFixture {
    let namespace = "com.pulkit.edith.tests.music-slots." + UUID().uuidString
    var calls = 0
    var payloads: [Data] = []
    var responses: [Data] = []
    var gate: MusicSlotsGate?
    var activeReads = 0
    var maximumConcurrentReads = 0
    func slots() -> HostMusicSlots {
        HostMusicSlots(namespace: namespace, minimumInterval: .zero) { [self] payload in
            payloads.append(payload); calls += 1; activeReads += 1
            maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
            defer { activeReads -= 1 }
            let response =
                responses.isEmpty
                ? try JSONEncoder().encode(
                    HostMusicSlotState(version: "1.0.0", footer: true, sidebar: false))
                : responses.removeFirst()
            if calls == 1, let gate { await gate.wait() }
            return response
        }
    }
}

@MainActor
private final class MusicSlotsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
