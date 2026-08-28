import AudioToolbox
import CoreAudio
import EdithCore
import Foundation

public struct AudioDeviceDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let uid: String
    public let name: String
    public let supportsInput: Bool
    public let supportsOutput: Bool
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
    public let isHeadphones: Bool

    public var id: String { uid }

    public init(
        uid: String, name: String, supportsInput: Bool, supportsOutput: Bool,
        isDefaultInput: Bool, isDefaultOutput: Bool, isHeadphones: Bool
    ) {
        self.uid = uid
        self.name = name
        self.supportsInput = supportsInput
        self.supportsOutput = supportsOutput
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
        self.isHeadphones = isHeadphones
    }
}

public struct AudioDeviceSnapshot: Codable, Equatable, Sendable {
    public let devices: [AudioDeviceDescriptor]
    public let defaultInputUID: String?
    public let defaultOutputUID: String?

    public init(
        devices: [AudioDeviceDescriptor], defaultInputUID: String?, defaultOutputUID: String?
    ) {
        self.devices = devices
        self.defaultInputUID = defaultInputUID
        self.defaultOutputUID = defaultOutputUID
    }

    public var inputs: [AudioDeviceDescriptor] { devices.filter(\.supportsInput) }
    public var outputs: [AudioDeviceDescriptor] { devices.filter(\.supportsOutput) }
}

public enum AudioDeviceOperationError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case coreAudio(String, OSStatus)
    case volumeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let device): "No available audio device matches \(device)."
        case .coreAudio(let action, let status):
            "\(action) failed with Core Audio status \(status)."
        case .volumeUnavailable(let device): "\(device) does not expose software volume control."
        }
    }
}

public enum AudioControlOperation: String, CaseIterable, Sendable {
    case status
    case selectInput
    case selectOutput
    case routeApp

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "audio.status"),
                summary: "Show audio devices, defaults, and saved application routes.",
                cli: ["audio", "status"], effect: .read)
        case .selectInput:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "audio.input"),
                summary: "Pin the preferred system audio input.",
                cli: ["audio", "input"], effect: .write)
        case .selectOutput:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "audio.output"),
                summary: "Switch the system audio output.",
                cli: ["audio", "output"], effect: .write)
        case .routeApp:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "audio.route"),
                summary: "Route one application's audio to an output device.",
                cli: ["audio", "route"], effect: .write)
        }
    }

    public var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Audio Controls settings", action: "inspect audio devices")
            ])
        case .selectInput:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Audio Controls settings", action: "pin preferred input",
                    exampleArguments: ["system"])
            ])
        case .selectOutput:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Audio Controls settings", action: "switch system output",
                    exampleArguments: ["device"])
            ])
        case .routeApp:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Notch Shelf audio mixer", action: "route application output",
                    exampleArguments: ["com.example.Player", "system"])
            ])
        }
    }
}

public enum AudioControlPolicy {
    public static func restorableInputUID(
        originalUID: String?, appliedUID: String?, currentUID: String?, availableUIDs: Set<String>
    ) -> String? {
        guard let originalUID, let appliedUID, originalUID != appliedUID else { return nil }
        guard currentUID == appliedUID, availableUIDs.contains(originalUID) else { return nil }
        return originalUID
    }

    public static func shouldLowerOutput(
        previousUID: String?, previousDevices: [AudioDeviceDescriptor],
        currentUID: String?, currentDevices: [AudioDeviceDescriptor], alreadyLoweredUID: String?
    ) -> Bool {
        guard let previousUID, let currentUID, currentUID != alreadyLoweredUID else { return false }
        guard previousDevices.first(where: { $0.uid == previousUID })?.isHeadphones == true else {
            return false
        }
        guard !currentDevices.contains(where: { $0.uid == previousUID && $0.isHeadphones }) else {
            return false
        }
        return currentDevices.first(where: { $0.uid == currentUID })?.isHeadphones == false
    }

    public static func shouldRestoreVolume(applied: Float, current: Float?) -> Bool {
        guard let current else { return false }
        return abs(current - applied) < 0.005
    }

    public static func routeMap(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        var routes: [String: String] = [:]
        for (bundleID, value) in raw {
            guard let uid = value as? String else { continue }
            let app = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let device = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty, !device.isEmpty, app.count <= 512, device.count <= 512 else {
                continue
            }
            routes[app] = device
        }
        return routes
    }
}

public enum AudioDeviceOperations {
    public static func snapshot() throws -> AudioDeviceSnapshot {
        let defaultInput = defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutput = defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let devices = try deviceIDs().compactMap { id -> AudioDeviceDescriptor? in
            guard isAlive(id), !isHidden(id), let uid = string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            let supportsInput = hasStreams(id, scope: kAudioObjectPropertyScopeInput)
            let supportsOutput = hasStreams(id, scope: kAudioObjectPropertyScopeOutput)
            guard supportsInput || supportsOutput else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return AudioDeviceDescriptor(
                uid: uid, name: name, supportsInput: supportsInput, supportsOutput: supportsOutput,
                isDefaultInput: uid == defaultInput, isDefaultOutput: uid == defaultOutput,
                isHeadphones: looksLikeHeadphones(name: name, uid: uid))
        }.sorted {
            if $0.isDefaultInput != $1.isDefaultInput { return $0.isDefaultInput }
            if $0.isDefaultOutput != $1.isDefaultOutput { return $0.isDefaultOutput }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return AudioDeviceSnapshot(
            devices: devices, defaultInputUID: defaultInput, defaultOutputUID: defaultOutput)
    }

    public static func resolve(_ value: String, among devices: [AudioDeviceDescriptor])
        -> AudioDeviceDescriptor?
    {
        if let exact = devices.first(where: { $0.uid == value }) { return exact }
        let matches = devices.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func setDefaultInput(uid: String) throws {
        let snapshot = try snapshot()
        guard let device = snapshot.inputs.first(where: { $0.uid == uid }),
            let id = deviceID(uid: device.uid)
        else { throw AudioDeviceOperationError.unavailable(uid) }
        try setDefault(
            id: id, selector: kAudioHardwarePropertyDefaultInputDevice, action: "Input switch")
    }

    public static func setDefaultOutput(uid: String) throws {
        let snapshot = try snapshot()
        guard let device = snapshot.outputs.first(where: { $0.uid == uid }),
            let id = deviceID(uid: device.uid)
        else { throw AudioDeviceOperationError.unavailable(uid) }
        try setDefault(
            id: id, selector: kAudioHardwarePropertyDefaultOutputDevice, action: "Output switch")
        try? setDefault(
            id: id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            action: "System sound output switch")
    }

    public static func outputVolume(uid: String) -> Float? {
        guard let id = deviceID(uid: uid) else { return nil }
        for selector in outputVolumeSelectors {
            var address = address(selector, scope: kAudioObjectPropertyScopeOutput)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    public static func setOutputVolume(uid: String, volume: Float) throws {
        guard let id = deviceID(uid: uid) else {
            throw AudioDeviceOperationError.unavailable(uid)
        }
        var value = min(max(volume, 0), 1)
        for selector in outputVolumeSelectors {
            var address = address(selector, scope: kAudioObjectPropertyScopeOutput)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(id, &address),
                AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue
            else { continue }
            let status = AudioObjectSetPropertyData(
                id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
            if status == noErr { return }
        }
        throw AudioDeviceOperationError.volumeUnavailable(uid)
    }

    private static let outputVolumeSelectors = [
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyVolumeScalar,
    ]

    private static func deviceIDs() throws -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size)
        guard sizeStatus == noErr else {
            throw AudioDeviceOperationError.coreAudio("Audio device discovery", sizeStatus)
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids)
        guard status == noErr else {
            throw AudioDeviceOperationError.coreAudio("Audio device discovery", status)
        }
        return ids
    }

    private static func deviceID(uid: String) -> AudioObjectID? {
        (try? deviceIDs())?.first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func defaultDeviceUID(selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
            id != 0
        else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    private static func setDefault(
        id: AudioObjectID, selector: AudioObjectPropertySelector, action: String
    ) throws {
        var property = address(selector)
        var value = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else { throw AudioDeviceOperationError.coreAudio(action, status) }
    }

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var property = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr
            && size >= MemoryLayout<AudioObjectID>.size
    }

    private static func isAlive(_ id: AudioObjectID) -> Bool {
        uint32(id, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? true
    }

    private static func isHidden(_ id: AudioObjectID) -> Bool {
        uint32(id, kAudioDevicePropertyIsHidden).map { $0 != 0 } ?? false
    }

    private static func string(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
            let result = value?.takeRetainedValue()
        else { return nil }
        return result as String
    }

    private static func uint32(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func looksLikeHeadphones(name: String, uid: String) -> Bool {
        let value = "\(name) \(uid)".folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: nil
        ).lowercased()
        let terms = [
            "headphone", "headset", "earphone", "earbud", "airpod", "earpod", "beats",
            "galaxy buds", "pixel buds", "bose qc", "sony wh", "sony wf", "jabra",
            "soundcore",
        ]
        return terms.contains { value.contains($0) }
    }
}
