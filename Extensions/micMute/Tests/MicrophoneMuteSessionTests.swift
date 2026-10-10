import Testing

@testable import MicMuteExtension

@Suite @MainActor struct MicrophoneMuteSessionTests {
    @Test func repeatedDeviceNotificationsPreserveOriginalVolumes() {
        let volume = MicrophoneControl(device: 1, element: 1, kind: .volume)
        let fixture = MicrophoneFixture(values: [volume: 0.7])
        let session = MicrophoneMuteSession(access: fixture.access)
        #expect(session.setMuted(true))
        #expect(session.setMuted(true))
        #expect(fixture.values[volume] == 0)
        #expect(session.setMuted(false))
        #expect(fixture.values[volume] == 0.7)
        #expect(session.saved.isEmpty)
    }

    @Test func microphonesAlreadyMutedKeepTheirOriginalState() {
        let first = MicrophoneControl(device: 1, element: 0, kind: .mute)
        let second = MicrophoneControl(device: 2, element: 0, kind: .mute)
        let fixture = MicrophoneFixture(values: [first: 1, second: 0])
        let session = MicrophoneMuteSession(access: fixture.access)
        #expect(session.setMuted(true))
        #expect(fixture.values == [first: 1, second: 1])
        #expect(session.setMuted(false))
        #expect(fixture.values == [first: 1, second: 0])
    }

    @Test func newlyConnectedChannelsAreIncludedWithoutLosingExistingValues() {
        let first = MicrophoneControl(device: 1, element: 1, kind: .volume)
        let second = MicrophoneControl(device: 2, element: 2, kind: .volume)
        let fixture = MicrophoneFixture(values: [first: 0.4])
        let session = MicrophoneMuteSession(access: fixture.access)
        #expect(session.setMuted(true))
        fixture.values[second] = 0.8
        #expect(session.setMuted(true))
        #expect(session.setMuted(false))
        #expect(fixture.values == [first: 0.4, second: 0.8])
    }

    @Test func failedWritesAreReportedAndDoNotAcquireRestorationState() {
        let control = MicrophoneControl(device: 1, element: 0, kind: .mute)
        let fixture = MicrophoneFixture(values: [control: 0])
        fixture.rejectWrites = true
        let session = MicrophoneMuteSession(access: fixture.access)
        #expect(!session.setMuted(true))
        #expect(session.saved.isEmpty)
        #expect(fixture.values[control] == 0)
    }

    @Test func failedRestorationCanBeRetriedAndSuccessfulShutdownIsIdempotent() {
        let control = MicrophoneControl(device: 1, element: 0, kind: .mute)
        let fixture = MicrophoneFixture(values: [control: 0])
        let session = MicrophoneMuteSession(access: fixture.access)
        #expect(session.setMuted(true))
        fixture.rejectWrites = true
        #expect(!session.setMuted(false))
        #expect(session.saved[control] == 0)
        fixture.rejectWrites = false
        #expect(session.setMuted(false))
        let writes = fixture.writes
        #expect(session.setMuted(false))
        #expect(fixture.writes == writes)
        #expect(fixture.values[control] == 0)
    }

    @Test func unreadableControlsAreLeftUnchanged() {
        let control = MicrophoneControl(device: 1, element: 0, kind: .mute)
        let fixture = MicrophoneFixture(values: [control: 0])
        fixture.rejectReads = true
        let session = MicrophoneMuteSession(access: fixture.access)
        #expect(!session.setMuted(true))
        #expect(fixture.writes == 0)
        #expect(session.saved.isEmpty)
    }
}

private final class MicrophoneFixture {
    var values: [MicrophoneControl: Float]
    var rejectReads = false
    var rejectWrites = false
    var writes = 0

    init(values: [MicrophoneControl: Float]) { self.values = values }

    var access: MicrophoneAccess {
        MicrophoneAccess(
            controls: { Array(self.values.keys) },
            read: { self.rejectReads ? nil : self.values[$0] },
            write: {
                self.writes += 1
                guard !self.rejectWrites else { return false }
                self.values[$0] = $1
                return true
            })
    }
}
