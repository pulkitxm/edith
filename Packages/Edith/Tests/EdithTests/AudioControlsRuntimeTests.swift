import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite(.serialized) @MainActor struct AudioControlsRuntimeTests {
    @Test func mediaKeyPolicyOnlyArmsForSupportedKeyDownEvents() {
        let playDown = (16 << 16) | (10 << 8)
        let playUp = (16 << 16) | (11 << 8)
        let volumeDown = (0 << 16) | (10 << 8)
        #expect(MusicLaunchBlockPolicy.shouldArm(data1: playDown))
        #expect(!MusicLaunchBlockPolicy.shouldArm(data1: playUp))
        #expect(!MusicLaunchBlockPolicy.shouldArm(data1: volumeDown))
    }

    @Test func launchPolicyUsesABoundedRecentMediaKeyWindow() {
        let key = Date(timeIntervalSince1970: 100)
        #expect(
            MusicLaunchBlockPolicy.shouldBlock(
                lastMediaKeyAt: key, launchAt: key.addingTimeInterval(1.9)))
        #expect(
            !MusicLaunchBlockPolicy.shouldBlock(
                lastMediaKeyAt: key, launchAt: key.addingTimeInterval(2.1)))
        #expect(
            !MusicLaunchBlockPolicy.shouldBlock(
                lastMediaKeyAt: key, launchAt: key.addingTimeInterval(-0.1)))
        #expect(!MusicLaunchBlockPolicy.shouldBlock(lastMediaKeyAt: nil, launchAt: key))
    }

    @Test func preferredInputRestoresOnlyWhileEngineOwnsTheSelection() throws {
        let suite = "test.audio-controls.input.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preferred", forKey: AppStorageKeys.Audio.preferredInputUID)
        var current = "original"
        var selections: [String] = []
        let devices = [
            device(uid: "original", name: "Built-in Mic", input: true),
            device(uid: "preferred", name: "Studio Mic", input: true),
        ]
        let engine = AudioControlsEngine(
            environment: AudioControlsEnvironment(
                snapshot: {
                    AudioDeviceSnapshot(
                        devices: devices, defaultInputUID: current, defaultOutputUID: nil)
                },
                setInput: {
                    selections.append($0)
                    current = $0
                }, outputVolume: { _ in nil }, setOutputVolume: { _, _ in }),
            defaults: defaults, startsMonitoring: false, managesMixer: false)

        engine.refresh()
        engine.shutdown()

        #expect(selections == ["preferred", "original"])

        selections.removeAll()
        current = "original"
        let second = AudioControlsEngine(
            environment: AudioControlsEnvironment(
                snapshot: {
                    AudioDeviceSnapshot(
                        devices: devices, defaultInputUID: current, defaultOutputUID: nil)
                },
                setInput: {
                    selections.append($0)
                    current = $0
                }, outputVolume: { _ in nil }, setOutputVolume: { _, _ in }),
            defaults: defaults, startsMonitoring: false, managesMixer: false)
        current = "manual"
        second.shutdown()

        #expect(selections == ["preferred"])
    }

    @Test func headphoneDisconnectLowersOnceAndRestoresOnlyUntouchedVolume() throws {
        let suite = "test.audio-controls.safety.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Audio.lowerOnHeadphoneDisconnect)
        defaults.set(25, forKey: AppStorageKeys.Audio.safeOutputPercent)
        var current = AudioDeviceSnapshot(
            devices: [
                device(uid: "headphones", name: "USB Headphones", output: true, headphones: true)
            ],
            defaultInputUID: nil, defaultOutputUID: "headphones")
        var volumes = ["speakers": Float(0.8)]
        var changes: [(String, Float)] = []
        let engine = AudioControlsEngine(
            environment: AudioControlsEnvironment(
                snapshot: { current }, setInput: { _ in },
                outputVolume: { volumes[$0] },
                setOutputVolume: {
                    volumes[$0] = $1
                    changes.append(($0, $1))
                }), defaults: defaults, startsMonitoring: false, managesMixer: false)

        current = AudioDeviceSnapshot(
            devices: [device(uid: "speakers", name: "Desk Speakers", output: true)],
            defaultInputUID: nil, defaultOutputUID: "speakers")
        engine.refresh()
        engine.refresh()
        #expect(changes.count == 1)
        #expect(changes.first?.0 == "speakers")
        #expect(changes.first?.1 == 0.25)

        current = AudioDeviceSnapshot(
            devices: [
                device(uid: "speakers", name: "Desk Speakers", output: true),
                device(uid: "headphones", name: "USB Headphones", output: true, headphones: true),
            ], defaultInputUID: nil, defaultOutputUID: "headphones")
        engine.refresh()
        #expect(changes.count == 2)
        #expect(changes.last?.1 == 0.8)

        current = AudioDeviceSnapshot(
            devices: [device(uid: "speakers", name: "Desk Speakers", output: true)],
            defaultInputUID: nil, defaultOutputUID: "speakers")
        volumes["speakers"] = 0.9
        engine.refresh()
        volumes["speakers"] = 0.5
        engine.shutdown()
        #expect(volumes["speakers"] == 0.5)
    }

    private func device(
        uid: String, name: String, input: Bool = false, output: Bool = false,
        headphones: Bool = false
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            uid: uid, name: name, supportsInput: input, supportsOutput: output,
            isDefaultInput: false, isDefaultOutput: false, isHeadphones: headphones)
    }
}
