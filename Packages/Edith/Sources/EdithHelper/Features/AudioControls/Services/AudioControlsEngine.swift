import EdithKit
import Foundation
import Observation

struct AudioControlsEnvironment {
    var snapshot: () throws -> AudioDeviceSnapshot
    var setInput: (String) throws -> Void
    var outputVolume: (String) -> Float?
    var setOutputVolume: (String, Float) throws -> Void

    static let live = AudioControlsEnvironment(
        snapshot: AudioDeviceOperations.snapshot,
        setInput: AudioDeviceOperations.setDefaultInput,
        outputVolume: AudioDeviceOperations.outputVolume,
        setOutputVolume: AudioDeviceOperations.setOutputVolume)
}

struct LoweredAudioOutput: Equatable {
    let uid: String
    let previous: Float
    let applied: Float
}

@MainActor
@Observable
final class AudioControlsEngine: FeatureModule {
    private(set) var snapshot = AudioDeviceSnapshot(
        devices: [], defaultInputUID: nil, defaultOutputUID: nil)
    private(set) var errorMessage: String?
    private(set) var originalInputUID: String?
    private(set) var appliedInputUID: String?
    private(set) var loweredOutput: LoweredAudioOutput?

    private let environment: AudioControlsEnvironment
    private let defaults: UserDefaults
    private let managesMixer: Bool
    private var monitorTask: Task<Void, Never>?
    private var previousSnapshot: AudioDeviceSnapshot?
    private var launchBlocker: MusicLaunchBlocker?
    private weak var music: MusicPlayer?

    required convenience init() {
        self.init(
            environment: .live, defaults: SharedDefaults.store, startsMonitoring: true,
            managesMixer: true)
    }

    init(
        environment: AudioControlsEnvironment, defaults: UserDefaults,
        startsMonitoring: Bool = true, managesMixer: Bool = true
    ) {
        self.environment = environment
        self.defaults = defaults
        self.managesMixer = managesMixer
        refresh()
        if startsMonitoring { startMonitoring() }
        if managesMixer, #available(macOS 14.4, *) { MixerEngine.shared.startService() }
        syncSettings()
    }

    func attachMusic(_ player: MusicPlayer?) {
        music = player
        syncLaunchBlocker()
    }

    func syncSettings() {
        pinPreferredInput()
        syncLaunchBlocker()
        if managesMixer, #available(macOS 14.4, *) {
            MixerEngine.shared.syncRoutes()
        }
    }

    func refresh() {
        do {
            let current = try environment.snapshot()
            applySafety(previous: previousSnapshot, current: current)
            snapshot = current
            previousSnapshot = current
            pinPreferredInput()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() {
        monitorTask?.cancel()
        monitorTask = nil
        launchBlocker?.stop()
        launchBlocker = nil
        if let current = try? environment.snapshot() { snapshot = current }
        restorePreferredInput()
        restoreLoweredOutput()
        if managesMixer, #available(macOS 14.4, *) { MixerEngine.shared.stopService() }
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                self?.refresh()
            }
        }
    }

    private func pinPreferredInput() {
        guard let preferred = defaults.string(forKey: AppStorageKeys.Audio.preferredInputUID),
            !preferred.isEmpty,
            snapshot.inputs.contains(where: { $0.uid == preferred }),
            snapshot.defaultInputUID != preferred
        else { return }
        if originalInputUID == nil { originalInputUID = snapshot.defaultInputUID }
        do {
            try environment.setInput(preferred)
            appliedInputUID = preferred
            snapshot = AudioDeviceSnapshot(
                devices: snapshot.devices.map { device in
                    AudioDeviceDescriptor(
                        uid: device.uid, name: device.name,
                        supportsInput: device.supportsInput,
                        supportsOutput: device.supportsOutput,
                        isDefaultInput: device.uid == preferred,
                        isDefaultOutput: device.isDefaultOutput,
                        isHeadphones: device.isHeadphones)
                }, defaultInputUID: preferred, defaultOutputUID: snapshot.defaultOutputUID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restorePreferredInput() {
        let available = Set(snapshot.inputs.map(\.uid))
        guard
            let uid = AudioControlPolicy.restorableInputUID(
                originalUID: originalInputUID, appliedUID: appliedInputUID,
                currentUID: snapshot.defaultInputUID, availableUIDs: available)
        else { return }
        try? environment.setInput(uid)
        originalInputUID = nil
        appliedInputUID = nil
    }

    private func applySafety(
        previous: AudioDeviceSnapshot?, current: AudioDeviceSnapshot
    ) {
        guard defaults.bool(forKey: AppStorageKeys.Audio.lowerOnHeadphoneDisconnect) else {
            return
        }
        if loweredOutput != nil,
            current.devices.contains(where: { $0.isHeadphones && $0.supportsOutput })
        {
            restoreLoweredOutput()
        }
        guard let previous,
            AudioControlPolicy.shouldLowerOutput(
                previousUID: previous.defaultOutputUID, previousDevices: previous.devices,
                currentUID: current.defaultOutputUID, currentDevices: current.devices,
                alreadyLoweredUID: loweredOutput?.uid),
            let uid = current.defaultOutputUID,
            let previousVolume = environment.outputVolume(uid)
        else { return }
        let percent = max(
            0, min(100, defaults.integer(forKey: AppStorageKeys.Audio.safeOutputPercent)))
        let applied = Float(percent) / 100
        guard previousVolume > applied else { return }
        do {
            try environment.setOutputVolume(uid, applied)
            loweredOutput = LoweredAudioOutput(
                uid: uid, previous: previousVolume, applied: applied)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreLoweredOutput() {
        guard let loweredOutput else { return }
        if AudioControlPolicy.shouldRestoreVolume(
            applied: loweredOutput.applied,
            current: environment.outputVolume(loweredOutput.uid))
        {
            try? environment.setOutputVolume(loweredOutput.uid, loweredOutput.previous)
        }
        self.loweredOutput = nil
    }

    private func syncLaunchBlocker() {
        let wanted = defaults.bool(forKey: AppStorageKeys.Audio.blockMusicLaunch)
        if wanted, launchBlocker == nil {
            let blocker = MusicLaunchBlocker { [weak self] in self?.music?.playPause() }
            blocker.start()
            launchBlocker = blocker
        }
        if !wanted {
            launchBlocker?.stop()
            launchBlocker = nil
        }
    }
}
