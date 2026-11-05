import Testing

@testable import TimeLapseExtension

@Suite struct TimeLapseGuidanceTests {
    @Test func polledOftenOnlyWhileRecording() {
        #expect(TimeLapseGuidance.pollInterval(recording: true) == .milliseconds(250))
        #expect(TimeLapseGuidance.pollInterval(recording: false) == .seconds(2))
    }

    @Test func explainsWhyRecordIsDisabled() {
        #expect(
            TimeLapseGuidance.startHint(
                canStart: true, busy: false, sourceMode: "displays", selectedCount: 1,
                loadingSources: false) == nil)
        #expect(
            TimeLapseGuidance.startHint(
                canStart: false, busy: true, sourceMode: "displays", selectedCount: 1,
                loadingSources: false) == nil)
        #expect(
            TimeLapseGuidance.startHint(
                canStart: false, busy: false, sourceMode: "displays", selectedCount: 0,
                loadingSources: true) == "Looking for displays and windows…")
        #expect(
            TimeLapseGuidance.startHint(
                canStart: false, busy: false, sourceMode: "displays", selectedCount: 0,
                loadingSources: false) == "Choose at least one display to enable Record.")
        #expect(
            TimeLapseGuidance.startHint(
                canStart: false, busy: false, sourceMode: "windows", selectedCount: 0,
                loadingSources: false) == "Choose at least one window to enable Record.")
    }

    @Test func describesEveryMode() {
        for mode in ScreenRecordingMode.allCases {
            #expect(!TimeLapseGuidance.modeSummary(mode).isEmpty)
        }
    }
}
