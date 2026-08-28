import AppKit
import CoreAudio
import EdithKit
import Testing
@testable import EdithHelper

private final class AudioMixerTapProbe: AudioMixerTapControlling {
    private(set) var gains: [Float] = []
    private(set) var destroyCount = 0

    func setGain(_ value: Float) {
        gains.append(value)
    }

    func destroy() {
        destroyCount += 1
    }
}

@Suite(.serialized) @MainActor struct AudioMixerRuntimeTests {
    @Test func failedTapCreationDoesNotPublishTheRequestedGain() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 41)
        var calls = 0
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: [app], outputUID: "output-a") },
            tapFactory: { _, _, _ in
                calls += 1
                return .failure(.deviceStart(-50))
            })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.4)

        #expect(calls == 1)
        #expect(engine.apps.first?.volume == 1)
        #expect(!engine.hasActiveTaps)
        #expect(engine.actionError?.contains("-50") == true)
    }

    @Test func retryPublishesGainOnlyAfterTapCreationRecovers() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 49)
        let tap = AudioMixerTapProbe()
        var shouldFail = true
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: [app], outputUID: "output-a") },
            tapFactory: { _, _, _ in
                if shouldFail { return .failure(.deviceStart(-50)) }
                return .success(tap)
            })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.4)
        #expect(engine.apps.first?.volume == 1)
        #expect(!engine.hasActiveTaps)

        shouldFail = false
        engine.retry()

        #expect(engine.apps.first?.volume == 0.4)
        #expect(engine.hasActiveTaps)
        #expect(engine.actionError == nil)
    }

    @Test func successfulTapPublishesGainAndOnlyOneRestoresFullVolume() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 42)
        let tap = AudioMixerTapProbe()
        var initialGains: [Float] = []
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: [app], outputUID: "output-a") },
            tapFactory: { _, _, gain in
                initialGains.append(gain)
                return .success(tap)
            })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.99)
        #expect(initialGains == [0.99])
        #expect(engine.apps.first?.volume == 0.99)
        #expect(engine.hasActiveTaps)

        engine.setVolume(try #require(engine.apps.first), 0.5)
        #expect(tap.gains == [0.5])
        #expect(engine.apps.first?.volume == 0.5)

        engine.setVolume(try #require(engine.apps.first), 1)
        #expect(tap.destroyCount == 1)
        #expect(engine.apps.first?.volume == 1)
        #expect(!engine.hasActiveTaps)

        engine.refresh()
        #expect(engine.apps.first?.volume == 1)
    }

    @Test func outputChangeRebuildsTapAndPreservesPublishedGain() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 43)
        let tap = AudioMixerTapProbe()
        var outputUID = "output-a"
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: [app], outputUID: outputUID) },
            tapFactory: { _, _, _ in .success(tap) })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.3)
        outputUID = "output-b"
        engine.refresh()

        #expect(tap.destroyCount == 1)
        #expect(engine.hasActiveTaps)
        #expect(engine.apps.first?.volume == 0.3)
    }

    @Test func vanishedAudioObjectDestroysItsTapAndGain() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 44)
        let tap = AudioMixerTapProbe()
        var apps = [app]
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: apps, outputUID: "output-a") },
            tapFactory: { _, _, _ in .success(tap) })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.2)
        apps = []
        engine.refresh()

        #expect(tap.destroyCount == 1)
        #expect(engine.apps.isEmpty)
        #expect(!engine.hasActiveTaps)
    }

    @Test func reusedProcessWithNewAudioObjectStartsAtFullVolume() throws {
        guard #available(macOS 14.4, *) else { return }
        let first = mixerApp(objectID: 45, pid: 700)
        let replacement = mixerApp(objectID: 46, pid: 700)
        let tap = AudioMixerTapProbe()
        var apps = [first]
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: apps, outputUID: "output-a") },
            tapFactory: { _, _, _ in .success(tap) })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.6)
        apps = [replacement]
        engine.refresh()

        #expect(tap.destroyCount == 1)
        #expect(engine.apps.first?.objectID == replacement.objectID)
        #expect(engine.apps.first?.volume == 1)
    }

    @Test func reusedAudioObjectWithNewProcessIdentityDestroysStaleTap() throws {
        guard #available(macOS 14.4, *) else { return }
        let first = mixerApp(objectID: 50, pid: 700)
        let replacement = mixerApp(objectID: 50, pid: 701)
        let tap = AudioMixerTapProbe()
        var apps = [first]
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: apps, outputUID: "output-a") },
            tapFactory: { _, _, _ in .success(tap) })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.6)
        apps = [replacement]
        engine.refresh()

        #expect(tap.destroyCount == 1)
        #expect(!engine.hasActiveTaps)
        #expect(engine.apps.first?.pid == replacement.pid)
        #expect(engine.apps.first?.volume == 1)
    }

    @Test func vanishedFailedAdjustmentClearsItsErrorAndCannotRetry() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 51)
        var apps = [app]
        var calls = 0
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: apps, outputUID: "output-a") },
            tapFactory: { _, _, _ in
                calls += 1
                return .failure(.deviceStart(-50))
            })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.4)
        #expect(engine.actionError != nil)
        apps = []
        engine.refresh()

        #expect(engine.actionError == nil)
        engine.retry()
        #expect(calls == 1)
        #expect(engine.actionError == nil)
    }

    @Test func transientDiscoveryFailurePreservesActiveState() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 47)
        let tap = AudioMixerTapProbe()
        var failure: AudioMixerDiscoveryError?
        let engine = MixerEngine(
            snapshotLoader: {
                if let failure { throw failure }
                return AudioMixerSnapshot(apps: [app], outputUID: "output-a")
            }, tapFactory: { _, _, _ in .success(tap) })
        defer { engine.shutdown() }

        engine.refresh()
        engine.setVolume(try #require(engine.apps.first), 0.7)
        failure = .processList(-1)
        engine.refresh()

        #expect(tap.destroyCount == 0)
        #expect(engine.hasActiveTaps)
        #expect(engine.apps.first?.volume == 0.7)
        #expect(engine.discoveryError?.contains("-1") == true)
    }

    @Test func visibilityOwnershipKeepsMonitoringUntilEveryViewCloses() {
        guard #available(macOS 14.4, *) else { return }
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: [], outputUID: "output-a") },
            tapFactory: { _, _, _ in .failure(.processTap(-1)) })
        defer { engine.shutdown() }

        engine.viewAppeared()
        engine.viewAppeared()
        #expect(engine.visibleViewCount == 2)
        #expect(engine.isMonitoring)

        engine.viewDisappeared()
        #expect(engine.visibleViewCount == 1)
        #expect(engine.isMonitoring)

        engine.viewDisappeared()
        #expect(engine.visibleViewCount == 0)
        #expect(!engine.isMonitoring)
    }

    @Test func shutdownIsIdempotentAndCancelsMonitoring() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = mixerApp(objectID: 48)
        let tap = AudioMixerTapProbe()
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: [app], outputUID: "output-a") },
            tapFactory: { _, _, _ in .success(tap) })

        engine.viewAppeared()
        engine.setVolume(try #require(engine.apps.first), 0.5)
        engine.shutdown()
        engine.shutdown()

        #expect(tap.destroyCount == 1)
        #expect(!engine.hasActiveTaps)
        #expect(!engine.isMonitoring)
        #expect(engine.visibleViewCount == 0)
        #expect(engine.apps.isEmpty)
    }

    @Test func savedRouteCreatesTapAtFullVolumeAndSystemRemovesIt() throws {
        guard #available(macOS 14.4, *) else { return }
        let suite = "test.audio-mixer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = mixerApp(objectID: 52)
        let output = AudioDeviceDescriptor(
            uid: "output-b", name: "Headphones", supportsInput: false, supportsOutput: true,
            isDefaultInput: false, isDefaultOutput: false, isHeadphones: true)
        let tap = AudioMixerTapProbe()
        var targets: [String] = []
        let engine = MixerEngine(
            snapshotLoader: {
                AudioMixerSnapshot(
                    apps: [app], outputUID: "output-a", outputs: [output])
            },
            tapFactory: { _, target, _ in
                targets.append(target)
                return .success(tap)
            }, defaults: defaults)
        defer { engine.shutdown() }

        defaults.set(
            [app.bundleID: output.uid], forKey: AppStorageKeys.Audio.appOutputRoutes)
        engine.startService()

        #expect(targets == ["output-b"])
        #expect(engine.apps.first?.outputUID == "output-b")
        #expect(engine.hasActiveTaps)

        engine.setOutput(try #require(engine.apps.first), nil)

        #expect(tap.destroyCount == 1)
        #expect(!engine.hasActiveTaps)
        #expect(engine.apps.first?.outputUID == nil)
        #expect(
            AudioControlPolicy.routeMap(
                defaults.dictionary(forKey: AppStorageKeys.Audio.appOutputRoutes)
            ).isEmpty)
    }

    @Test func serviceOwnershipKeepsMonitoringWithoutAVisibleView() {
        guard #available(macOS 14.4, *) else { return }
        let engine = MixerEngine(
            snapshotLoader: { AudioMixerSnapshot(apps: [], outputUID: "output-a") },
            tapFactory: { _, _, _ in .failure(.processTap(-1)) })
        defer { engine.shutdown() }

        engine.startService()
        #expect(engine.serviceEnabled)
        #expect(engine.isMonitoring)
        engine.stopService()
        #expect(!engine.serviceEnabled)
        #expect(!engine.isMonitoring)
    }

    @Test func stoppingServiceRemovesRoutesAndPreservesIndependentVolume() throws {
        guard #available(macOS 14.4, *) else { return }
        let suite = "test.audio-mixer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = mixerApp(objectID: 53)
        let output = AudioDeviceDescriptor(
            uid: "output-b", name: "Headphones", supportsInput: false, supportsOutput: true,
            isDefaultInput: false, isDefaultOutput: false, isHeadphones: true)
        var taps: [AudioMixerTapProbe] = []
        var targets: [String] = []
        let engine = MixerEngine(
            snapshotLoader: {
                AudioMixerSnapshot(apps: [app], outputUID: "output-a", outputs: [output])
            },
            tapFactory: { _, target, _ in
                let tap = AudioMixerTapProbe()
                taps.append(tap)
                targets.append(target)
                return .success(tap)
            }, defaults: defaults)
        defer { engine.shutdown() }

        defaults.set(
            [app.bundleID: output.uid], forKey: AppStorageKeys.Audio.appOutputRoutes)
        engine.startService()
        engine.setVolume(try #require(engine.apps.first), 0.4)
        engine.stopService()

        #expect(targets == ["output-b", "output-a"])
        #expect(taps.first?.destroyCount == 1)
        #expect(engine.apps.first?.outputUID == nil)
        #expect(engine.apps.first?.volume == 0.4)
        #expect(engine.hasActiveTaps)
        #expect(engine.isMonitoring)
    }

    private func mixerApp(
        objectID: AudioObjectID, pid: pid_t = 600, volume: Float = 1
    ) -> MixerApp {
        MixerApp(
            objectID: objectID, pid: pid, bundleID: "com.example.audio", name: "Audio App",
            icon: nil, volume: volume)
    }
}
