import AppKit
import CoreAudio
import EdithKit
import Observation

struct MixerApp: Identifiable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    var volume: Float
    var outputUID: String? = nil
    var id: AudioObjectID { objectID }
}

protocol AudioMixerTapControlling: AnyObject {
    func setGain(_ value: Float)
    func destroy()
}

enum AudioMixerTapError: Error, Equatable {
    case processTap(OSStatus)
    case tapUID(OSStatus)
    case aggregateDevice(OSStatus)
    case ioProcessor(OSStatus)
    case deviceStart(OSStatus)

    var message: String {
        switch self {
        case let .processTap(status):
            "Application audio access failed with Core Audio status \(status)."
        case let .tapUID(status):
            "The application audio tap could not be prepared, Core Audio status \(status)."
        case let .aggregateDevice(status):
            "The application audio route failed with Core Audio status \(status)."
        case let .ioProcessor(status):
            "Audio processing failed to start with Core Audio status \(status)."
        case let .deviceStart(status):
            "The audio device failed to start with Core Audio status \(status)."
        }
    }
}

enum AudioMixerDiscoveryError: Error, Equatable {
    case processList(OSStatus)
    case defaultOutput(OSStatus)
    case outputUID(OSStatus)

    var message: String {
        switch self {
        case let .processList(status):
            "Audio apps could not be refreshed, Core Audio status \(status)."
        case let .defaultOutput(status):
            "The current audio output is unavailable, Core Audio status \(status)."
        case let .outputUID(status):
            "The current audio output has no usable identifier, Core Audio status \(status)."
        }
    }
}

@available(macOS 14.4, *)
enum AudioProcessRegistry {
    static func audioProcesses() throws
        -> [(objectID: AudioObjectID, pid: pid_t, bundleID: String)]
    {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            throw AudioMixerDiscoveryError.processList(sizeStatus)
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let listStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        guard listStatus == noErr else {
            throw AudioMixerDiscoveryError.processList(listStatus)
        }
        return ids.compactMap { object in
            let pid = intProperty(object, kAudioProcessPropertyPID)
            guard pid > 0, let bundleID = stringProperty(object, kAudioProcessPropertyBundleID),
                !bundleID.isEmpty,
                intProperty(object, kAudioProcessPropertyIsRunningOutput) != 0
            else { return nil }
            return (object, pid_t(pid), bundleID)
        }
    }

    private static func intProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    )
        -> Int32
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = -1
        var size = UInt32(MemoryLayout<Int32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
            let string = value?.takeRetainedValue()
        else { return nil }
        return string as String
    }

    static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard deviceStatus == noErr else {
            throw AudioMixerDiscoveryError.defaultOutput(deviceStatus)
        }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(
            device, &uidAddress, 0, nil, &uidSize, &uid)
        guard uidStatus == noErr,
            let value = uid?.takeRetainedValue()
        else { throw AudioMixerDiscoveryError.outputUID(uidStatus) }
        return value as String
    }
}

@available(macOS 14.4, *)
final class AppVolumeTap: AudioMixerTapControlling, @unchecked Sendable {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.pulkit.edith.audiomixer.tap")
    private var gain: Float

    func setGain(_ value: Float) {
        queue.sync { gain = max(0, min(1, value)) }
    }

    init(processObjectID: AudioObjectID, outputUID: String, initialGain: Float) throws {
        gain = max(0, min(1, initialGain))
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != 0 else {
            throw AudioMixerTapError.processTap(tapStatus)
        }
        tapID = tap
        let tapIdentifier: String
        do {
            tapIdentifier = try tapUID(tap)
        } catch {
            destroy()
            throw error
        }
        let aggregateUID = "com.pulkit.edith.tap.\(UUID().uuidString)"
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Edith Mixer",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapIdentifier, kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var aggregate = AudioDeviceID(0)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            dictionary as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != 0
        else {
            destroy()
            throw AudioMixerTapError.aggregateDevice(aggregateStatus)
        }
        aggregateID = aggregate
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) {
            [weak self] _, input, _, output, _ in
            guard let self else { return }
            let level = self.gain
            let inBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: input))
            let outBuffers = UnsafeMutableAudioBufferListPointer(output)
            for index in 0..<min(inBuffers.count, outBuffers.count) {
                let source = inBuffers[index]
                let destination = outBuffers[index]
                guard let sourceData = source.mData, let destinationData = destination.mData
                else { continue }
                let byteCount = Int(min(source.mDataByteSize, destination.mDataByteSize))
                let sampleCount = byteCount / MemoryLayout<Float>.size
                let sourceSamples = sourceData.assumingMemoryBound(to: Float.self)
                let destinationSamples = destinationData.assumingMemoryBound(to: Float.self)
                for sample in 0..<sampleCount {
                    destinationSamples[sample] = sourceSamples[sample] * level
                }
            }
        }
        guard status == noErr, let proc else {
            destroy()
            throw AudioMixerTapError.ioProcessor(status)
        }
        procID = proc
        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else {
            destroy()
            throw AudioMixerTapError.deviceStart(startStatus)
        }
    }

    private func tapUID(_ tap: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &value)
        guard status == noErr,
            let string = value?.takeRetainedValue()
        else { throw AudioMixerTapError.tapUID(status) }
        return string as String
    }

    func destroy() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { destroy() }
}

struct AudioMixerSnapshot {
    let apps: [MixerApp]
    let outputUID: String
    var outputs: [AudioDeviceDescriptor] = []
}

typealias AudioMixerSnapshotLoader = @MainActor () throws -> AudioMixerSnapshot
typealias AudioMixerTapFactory =
    @MainActor (
        AudioObjectID, String, Float
    ) -> Result<any AudioMixerTapControlling, AudioMixerTapError>

@available(macOS 14.4, *)
@MainActor
@Observable
final class MixerEngine {
    static let shared = MixerEngine()

    private(set) var apps: [MixerApp] = []
    private(set) var actionError: String?
    private(set) var discoveryError: String?
    private(set) var visibleViewCount = 0
    private(set) var isMonitoring = false
    private(set) var outputDevices: [AudioDeviceDescriptor] = []
    private(set) var serviceEnabled = false

    var errorMessage: String? { actionError ?? discoveryError }
    var hasActiveTaps: Bool { !taps.isEmpty }

    private let snapshotLoader: AudioMixerSnapshotLoader
    private let tapFactory: AudioMixerTapFactory
    private let defaults: UserDefaults
    private var outputUID: String?
    private var taps: [AudioObjectID: any AudioMixerTapControlling] = [:]
    private var tapOutputUIDs: [AudioObjectID: String] = [:]
    private var gains: [AudioObjectID: Float] = [:]
    private var failedAdjustment: (app: MixerApp, value: Float)?
    private var actionErrorObjectID: AudioObjectID?
    private var monitoringTask: Task<Void, Never>?

    init(
        snapshotLoader: @escaping AudioMixerSnapshotLoader = MixerEngine.liveSnapshot,
        tapFactory: @escaping AudioMixerTapFactory = MixerEngine.liveTap,
        defaults: UserDefaults = SharedDefaults.store
    ) {
        self.snapshotLoader = snapshotLoader
        self.tapFactory = tapFactory
        self.defaults = defaults
    }

    func startService() {
        serviceEnabled = true
        refresh()
        reconcileMonitoring()
    }

    func stopService() {
        serviceEnabled = false
        if visibleViewCount == 0 {
            destroyAllTaps()
            gains.removeAll()
            apps.removeAll()
        }
        reconcileMonitoring()
    }

    func syncRoutes() {
        refresh()
    }

    func viewAppeared() {
        visibleViewCount += 1
        refresh()
        reconcileMonitoring()
    }

    func viewDisappeared() {
        visibleViewCount = max(0, visibleViewCount - 1)
        reconcileMonitoring()
    }

    func refresh() {
        do {
            apply(try snapshotLoader())
            discoveryError = nil
        } catch let error as AudioMixerDiscoveryError {
            discoveryError = error.message
        } catch {
            discoveryError = "Audio apps could not be refreshed."
        }
    }

    func setVolume(_ app: MixerApp, _ requestedValue: Float) {
        guard apps.contains(where: { Self.sameProcess($0, app) }) else {
            actionError = "\(app.name) is no longer producing audio."
            actionErrorObjectID = app.objectID
            failedAdjustment = nil
            return
        }
        let value = max(0, min(1, requestedValue))
        let routeUID = routeUID(for: app.bundleID)
        if value == 1, routeUID == nil {
            taps.removeValue(forKey: app.objectID)?.destroy()
            tapOutputUIDs.removeValue(forKey: app.objectID)
            gains.removeValue(forKey: app.objectID)
            publish(app.objectID, volume: 1)
            actionError = nil
            actionErrorObjectID = nil
            failedAdjustment = nil
            reconcileMonitoring()
            return
        }
        let desiredOutputUID = routeUID ?? outputUID
        if let tap = taps[app.objectID], tapOutputUIDs[app.objectID] == desiredOutputUID {
            tap.setGain(value)
            publish(app.objectID, volume: value)
            actionError = nil
            actionErrorObjectID = nil
            failedAdjustment = nil
            return
        }
        guard let desiredOutputUID else {
            actionError = "The current audio output is unavailable."
            actionErrorObjectID = app.objectID
            failedAdjustment = (app, value)
            return
        }
        taps.removeValue(forKey: app.objectID)?.destroy()
        tapOutputUIDs.removeValue(forKey: app.objectID)
        switch tapFactory(app.objectID, desiredOutputUID, value) {
        case let .success(tap):
            taps[app.objectID] = tap
            tapOutputUIDs[app.objectID] = desiredOutputUID
            publish(app.objectID, volume: value)
            actionError = nil
            actionErrorObjectID = nil
            failedAdjustment = nil
            reconcileMonitoring()
        case let .failure(error):
            actionError = "Could not change \(app.name)'s volume. \(error.message)"
            actionErrorObjectID = app.objectID
            failedAdjustment = (app, value)
        }
    }

    func setOutput(_ app: MixerApp, _ requestedUID: String?) {
        guard apps.contains(where: { Self.sameProcess($0, app) }) else {
            actionError = "\(app.name) is no longer producing audio."
            actionErrorObjectID = app.objectID
            return
        }
        let uid = requestedUID.flatMap { value in
            outputDevices.contains(where: { $0.uid == value }) ? value : nil
        }
        var routes = routeMap()
        if let uid {
            routes[app.bundleID] = uid
        } else {
            routes.removeValue(forKey: app.bundleID)
        }
        defaults.set(routes, forKey: AppStorageKeys.Audio.appOutputRoutes)
        defaults.synchronize()
        publish(app.objectID, outputUID: uid)
        setVolume(apps.first(where: { $0.objectID == app.objectID }) ?? app, app.volume)
    }

    func retry() {
        refresh()
        guard let failedAdjustment,
            let app = apps.first(where: { Self.sameProcess($0, failedAdjustment.app) })
        else {
            actionError = nil
            actionErrorObjectID = nil
            self.failedAdjustment = nil
            return
        }
        setVolume(app, failedAdjustment.value)
    }

    func shutdown() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        visibleViewCount = 0
        serviceEnabled = false
        destroyAllTaps()
        gains.removeAll()
        outputUID = nil
        outputDevices.removeAll()
        apps.removeAll()
        actionError = nil
        actionErrorObjectID = nil
        discoveryError = nil
        failedAdjustment = nil
    }

    private func apply(_ snapshot: AudioMixerSnapshot) {
        if let outputUID, outputUID != snapshot.outputUID {
            destroyAllTaps()
            actionError = nil
            actionErrorObjectID = nil
            failedAdjustment = nil
        }
        outputUID = snapshot.outputUID
        outputDevices = snapshot.outputs
        let routes = routeMap()

        var previousApps: [AudioObjectID: MixerApp] = [:]
        for app in apps { previousApps[app.objectID] = app }
        var seen: Set<AudioObjectID> = []
        var currentApps: [MixerApp] = []
        var currentIDs: Set<AudioObjectID> = []
        var replacedIDs: Set<AudioObjectID> = []
        for app in snapshot.apps where seen.insert(app.objectID).inserted {
            var current = app
            current.outputUID = routes[app.bundleID]
            currentApps.append(current)
            currentIDs.insert(app.objectID)
            if let previous = previousApps[app.objectID], !Self.sameProcess(previous, app) {
                replacedIDs.insert(app.objectID)
            }
        }
        var retiredIDs: [AudioObjectID] = []
        for objectID in taps.keys
        where !currentIDs.contains(objectID) || replacedIDs.contains(objectID) {
            retiredIDs.append(objectID)
        }
        for objectID in retiredIDs {
            taps.removeValue(forKey: objectID)?.destroy()
            tapOutputUIDs.removeValue(forKey: objectID)
            gains.removeValue(forKey: objectID)
        }
        for objectID in Array(gains.keys)
        where !currentIDs.contains(objectID) || replacedIDs.contains(objectID) {
            gains.removeValue(forKey: objectID)
        }
        if let actionErrorObjectID,
            !currentIDs.contains(actionErrorObjectID)
                || replacedIDs.contains(actionErrorObjectID)
        {
            actionError = nil
            self.actionErrorObjectID = nil
            failedAdjustment = nil
        }
        apps = currentApps
        for index in apps.indices {
            let app = apps[index]
            var current = app
            current.volume = gains[app.objectID] ?? 1
            apps[index] = current
        }
        for app in apps where app.outputUID != nil || app.volume < 1 {
            setVolume(app, app.volume)
        }
        reconcileMonitoring()
    }

    private static func sameProcess(_ lhs: MixerApp, _ rhs: MixerApp) -> Bool {
        lhs.objectID == rhs.objectID && lhs.pid == rhs.pid && lhs.bundleID == rhs.bundleID
    }

    private func publish(_ objectID: AudioObjectID, volume: Float) {
        if volume == 1 {
            gains.removeValue(forKey: objectID)
        } else {
            gains[objectID] = volume
        }
        guard let index = apps.firstIndex(where: { $0.objectID == objectID }) else { return }
        apps[index].volume = volume
    }

    private func publish(_ objectID: AudioObjectID, outputUID: String?) {
        guard let index = apps.firstIndex(where: { $0.objectID == objectID }) else { return }
        apps[index].outputUID = outputUID
    }

    private func routeUID(for bundleID: String) -> String? {
        let uid = routeMap()[bundleID]
        return uid.flatMap { value in
            outputDevices.contains(where: { $0.uid == value }) ? value : nil
        }
    }

    private func routeMap() -> [String: String] {
        AudioControlPolicy.routeMap(
            defaults.dictionary(forKey: AppStorageKeys.Audio.appOutputRoutes))
    }

    private func destroyAllTaps() {
        for tap in taps.values { tap.destroy() }
        taps.removeAll()
        tapOutputUIDs.removeAll()
    }

    private func reconcileMonitoring() {
        let shouldMonitor = serviceEnabled || visibleViewCount > 0 || !taps.isEmpty
        if shouldMonitor, monitoringTask == nil {
            isMonitoring = true
            monitoringTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    self?.refresh()
                }
            }
        } else if !shouldMonitor {
            monitoringTask?.cancel()
            monitoringTask = nil
            isMonitoring = false
        }
    }

    private static func liveSnapshot() throws -> AudioMixerSnapshot {
        let processes = try AudioProcessRegistry.audioProcesses()
        let apps = processes.map { process in
            let app = NSRunningApplication(processIdentifier: process.pid)
            return MixerApp(
                objectID: process.objectID, pid: process.pid, bundleID: process.bundleID,
                name: app?.localizedName ?? process.bundleID, icon: app?.icon, volume: 1)
        }
        let devices = try AudioDeviceOperations.snapshot()
        return AudioMixerSnapshot(
            apps: apps, outputUID: try AudioProcessRegistry.defaultOutputUID(),
            outputs: devices.outputs)
    }

    private static func liveTap(
        processObjectID: AudioObjectID, outputUID: String, initialGain: Float
    ) -> Result<any AudioMixerTapControlling, AudioMixerTapError> {
        do {
            return .success(
                try AppVolumeTap(
                    processObjectID: processObjectID, outputUID: outputUID,
                    initialGain: initialGain))
        } catch let error as AudioMixerTapError {
            return .failure(error)
        } catch {
            return .failure(.processTap(-1))
        }
    }
}
