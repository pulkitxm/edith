import Testing

@testable import EdithKit

struct AudioDeviceOperationTests {
    @Test func inputRestorationOnlyAppliesWhilePinStillOwnsTheDefault() {
        #expect(
            AudioControlPolicy.restorableInputUID(
                originalUID: "built-in", appliedUID: "usb", currentUID: "usb",
                availableUIDs: ["built-in", "usb"]) == "built-in")
        #expect(
            AudioControlPolicy.restorableInputUID(
                originalUID: "built-in", appliedUID: "usb", currentUID: "studio",
                availableUIDs: ["built-in", "usb", "studio"]) == nil)
    }

    @Test func headphoneRemovalLowersOnlyTheNewSpeakerOutputOnce() {
        let headphones = device("headphones", headphones: true)
        let speakers = device("speakers", headphones: false)
        #expect(
            AudioControlPolicy.shouldLowerOutput(
                previousUID: headphones.uid, previousDevices: [headphones, speakers],
                currentUID: speakers.uid, currentDevices: [speakers], alreadyLoweredUID: nil))
        #expect(
            !AudioControlPolicy.shouldLowerOutput(
                previousUID: headphones.uid, previousDevices: [headphones, speakers],
                currentUID: speakers.uid, currentDevices: [speakers],
                alreadyLoweredUID: speakers.uid))
    }

    @Test func automaticVolumeRestorationDoesNotOverrideAUserChange() {
        #expect(AudioControlPolicy.shouldRestoreVolume(applied: 0.25, current: 0.25))
        #expect(!AudioControlPolicy.shouldRestoreVolume(applied: 0.25, current: 0.4))
    }

    @Test func routeMapDropsMalformedEntries() {
        let routes = AudioControlPolicy.routeMap([
            "com.example.Player": "output-a", "": "output-b", "bad": 42,
        ])
        #expect(routes == ["com.example.Player": "output-a"])
    }

    @Test func headphoneNamesAreRecognized() {
        #expect(AudioDeviceOperations.looksLikeHeadphones(name: "Pulkit's AirPods", uid: "a"))
        #expect(!AudioDeviceOperations.looksLikeHeadphones(name: "Studio Display", uid: "b"))
    }

    private func device(_ uid: String, headphones: Bool) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            uid: uid, name: uid, supportsInput: false, supportsOutput: true,
            isDefaultInput: false, isDefaultOutput: false, isHeadphones: headphones)
    }
}
