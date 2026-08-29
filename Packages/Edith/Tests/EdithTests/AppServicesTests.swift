import EdithKit
import Foundation
import Testing
@testable import EdithHelper

private actor AppServicesLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AppServicesCallProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@Suite(.serialized) @MainActor struct AppServicesTests {
    private let probe = "tabEnabledProbeKey"

    @Test func constructionDoesNotEagerlyStartExtensionServices() {
        let services = AppServices()

        #expect(services.usage == nil)
        #expect(services.music == nil)
        #expect(services.system == nil)
        #expect(services.machines == nil)
        #expect(services.calendar == nil)
        #expect(services.notchShelf == nil)
        #expect(services.colorPicker == nil)
        #expect(services.clipboard == nil)
        #expect(services.finderTools == nil)
        #expect(services.focusDim == nil)
        #expect(services.presenter == nil)
        #expect(services.micMute == nil)
        #expect(services.lidAwake == nil)
        #expect(services.systemStats == nil)
        #expect(services.attention == nil)
    }

    @Test func extensionDefaultsToDisabledWhenUnset() {
        SharedDefaults.store.removeObject(forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(!AppServices.extensionEnabled(probe))
    }

    @Test func extensionRespectsExplicitDisable() {
        SharedDefaults.store.set(false, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(!AppServices.extensionEnabled(probe))
    }

    @Test func extensionRespectsExplicitEnable() {
        SharedDefaults.store.set(true, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.extensionEnabled(probe))
    }

    @Test func audioMixerRuntimeRequiresBothShelfAndNestedEnablement() {
        #expect(
            AppServices.audioMixerRuntimeEnabled(
                notchShelfEnabled: true, mixerEnabled: true))
        #expect(
            !AppServices.audioMixerRuntimeEnabled(
                notchShelfEnabled: false, mixerEnabled: true))
        #expect(
            !AppServices.audioMixerRuntimeEnabled(
                notchShelfEnabled: true, mixerEnabled: false))
        #expect(
            !AppServices.audioMixerRuntimeEnabled(
                notchShelfEnabled: false, mixerEnabled: false))
    }

    @Test func preferenceDefaultsToEnabledWhenUnset() {
        SharedDefaults.store.removeObject(forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.preferenceOnByDefault(probe))
    }

    @Test func preferenceRespectsExplicitDisable() {
        SharedDefaults.store.set(false, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(!AppServices.preferenceOnByDefault(probe))
    }

    @Test func preferenceRespectsExplicitEnable() {
        SharedDefaults.store.set(true, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.preferenceOnByDefault(probe))
    }

    @Test func attentionRuntimeRequiresTheExtensionAndATrackingSource() {
        #expect(
            !AppServices.attentionEnabled(
                extensionEnabled: false,
                settings: AttentionSettings(isEnabled: true, trackingEnabled: true)))
        #expect(
            !AppServices.attentionEnabled(
                extensionEnabled: true, settings: AttentionSettings(isEnabled: true)))
        #expect(
            AppServices.attentionEnabled(
                extensionEnabled: true,
                settings: AttentionSettings(isEnabled: true, trackingEnabled: true)))
        #expect(
            AppServices.attentionEnabled(
                extensionEnabled: true,
                settings: AttentionSettings(isEnabled: true, browserTrackingEnabled: true)))
    }

    @Test func failedLidAwakeDisableRequiresRecovery() {
        #expect(AppServices.lidAwakeDisableRecovery(.applied) == nil)
        #expect(AppServices.lidAwakeDisableRecovery(.failed("pmset refused")) == "pmset refused")
        #expect(
            AppServices.lidAwakeRuntimeWanted(
                extensionEnabled: true, engineAvailable: false, restorationInFlight: false))
        #expect(
            !AppServices.lidAwakeRuntimeWanted(
                extensionEnabled: true, engineAvailable: false, restorationInFlight: true))
    }

    @Test func orphanRecoveryIsSingleFlightAcrossConcurrentCallers() async {
        let defaults = SharedDefaults.store
        let priorEnabled = defaults.object(forKey: LidAwakeState.enabledKey)
        let priorActive = defaults.object(forKey: LidAwakeState.activeKey)
        defer {
            restore(priorEnabled, key: LidAwakeState.enabledKey, defaults: defaults)
            restore(priorActive, key: LidAwakeState.activeKey, defaults: defaults)
        }
        defaults.set(false, forKey: LidAwakeState.enabledKey)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        let started = AppServicesLatch()
        let release = AppServicesLatch()
        let calls = AppServicesCallProbe()
        let services = AppServices {
            await calls.record()
            await started.release()
            await release.wait()
            defaults.set(false, forKey: LidAwakeState.activeKey)
            return .applied
        }
        await services.prepareForTermination()

        let first = Task { @MainActor in await services.recoverOrphanedLidAwake() }
        await started.wait()
        let second = Task { @MainActor in await services.recoverOrphanedLidAwake() }
        for _ in 0..<20 { await Task.yield() }

        #expect(await calls.count == 1)
        #expect(services.lidAwakeRestorationInFlight)

        await release.release()
        #expect(await first.value == .applied)
        #expect(await second.value == .applied)
        #expect(await calls.count == 1)
        #expect(!services.lidAwakeRestorationInFlight)
        #expect(!defaults.bool(forKey: LidAwakeState.enabledKey))
    }

    @Test func failedOrphanRecoveryReenablesTheExtension() async {
        let defaults = SharedDefaults.store
        let priorEnabled = defaults.object(forKey: LidAwakeState.enabledKey)
        let priorActive = defaults.object(forKey: LidAwakeState.activeKey)
        defer {
            restore(priorEnabled, key: LidAwakeState.enabledKey, defaults: defaults)
            restore(priorActive, key: LidAwakeState.activeKey, defaults: defaults)
        }
        defaults.set(false, forKey: LidAwakeState.enabledKey)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        let services = AppServices {
            .failed("restore refused")
        }
        await services.prepareForTermination()

        let outcome = await services.recoverOrphanedLidAwake()

        #expect(outcome == .failed("restore refused"))
        #expect(defaults.bool(forKey: LidAwakeState.enabledKey))
        #expect(defaults.bool(forKey: LidAwakeState.activeKey))
    }

    @Test func runtimeOffRecoveryPreservesAnEnabledExtension() async {
        let defaults = SharedDefaults.store
        let priorEnabled = defaults.object(forKey: LidAwakeState.enabledKey)
        let priorActive = defaults.object(forKey: LidAwakeState.activeKey)
        defer {
            restore(priorEnabled, key: LidAwakeState.enabledKey, defaults: defaults)
            restore(priorActive, key: LidAwakeState.activeKey, defaults: defaults)
        }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        let services = AppServices {
            defaults.set(false, forKey: LidAwakeState.activeKey)
            return .applied
        }
        await services.prepareForTermination()

        let outcome = await services.recoverOrphanedLidAwake()

        #expect(outcome == .applied)
        #expect(defaults.bool(forKey: LidAwakeState.enabledKey))
        #expect(!defaults.bool(forKey: LidAwakeState.activeKey))
    }

    @Test func disabledExtensionRecoversAPersistedPendingRestoration() async {
        let defaults = SharedDefaults.store
        let priorEnabled = defaults.object(forKey: LidAwakeState.enabledKey)
        let priorActive = defaults.object(forKey: LidAwakeState.activeKey)
        let priorPending = defaults.object(forKey: LidAwakeState.automaticStopPendingKey)
        defer {
            restore(priorEnabled, key: LidAwakeState.enabledKey, defaults: defaults)
            restore(priorActive, key: LidAwakeState.activeKey, defaults: defaults)
            restore(priorPending, key: LidAwakeState.automaticStopPendingKey, defaults: defaults)
        }
        defaults.set(false, forKey: LidAwakeState.enabledKey)
        defaults.set(false, forKey: LidAwakeState.activeKey)
        LidAwakeState.setAutomaticStopPending(true, defaults)
        let started = AppServicesLatch()
        let release = AppServicesLatch()
        let calls = AppServicesCallProbe()
        let services = AppServices {
            await calls.record()
            await started.release()
            await release.wait()
            LidAwakeState.setAutomaticStopPending(false, defaults)
            return .applied
        }
        await services.prepareForTermination()

        services.reconcileLidAwakeService()
        await started.wait()
        let outcome = Task { @MainActor in await services.waitForLidAwakeRestoration() }

        #expect(await calls.count == 1)
        #expect(services.lidAwakeRestorationInFlight)
        await release.release()
        #expect(await outcome.value == .applied)
        #expect(!LidAwakeState.automaticStopPending(defaults))
        #expect(!defaults.bool(forKey: LidAwakeState.enabledKey))
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
