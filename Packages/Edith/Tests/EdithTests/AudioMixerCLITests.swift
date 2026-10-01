import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct AudioMixerCLITests {
    @Test func anExactBundleBeatsASharedName() throws {
        let apps = [
            AudioMixerAppRecord(
                objectID: 1, pid: 10, bundleID: "com.example.music", name: "Music", volume: 1),
            AudioMixerAppRecord(
                objectID: 2, pid: 11, bundleID: "com.example.other", name: "Music", volume: 0.4),
        ]
        let match = try AudioMixerSelector.match("com.example.other", in: apps)
        #expect(match.pid == 11)
        #expect(throws: AudioMixerSelectionError.self) {
            try AudioMixerSelector.match("Music", in: apps)
        }
    }

    @Test func aProcessIdMatchesWhenTheNameDoesNot() throws {
        let apps = [
            AudioMixerAppRecord(
                objectID: 4, pid: 440, bundleID: "com.example.browser", name: "Browser",
                volume: 0)
        ]
        let match = try AudioMixerSelector.match("440", in: apps)
        #expect(match.muted)
        #expect(match.percent == 0)
    }

    @Test func volumeOutsideTheSliderIsRejected() throws {
        #expect(throws: CLIFailure.self) { try AudioCLI.percent(140) }
        #expect(try AudioCLI.percent(40) == 0.4)
    }

    @Test func helpNamesTheMixerExample() {
        let help = AudioVolumeCommand.helpMessage(columns: 200)
        #expect(help.contains("ed audio volume Music 40 --json"))
        #expect(help.contains("0 to 100"))
    }
}
