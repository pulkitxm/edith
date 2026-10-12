import Testing

@testable import EdithHostCore

struct HostRemoteIdentitySelectionTests {
    @Test func selectsOnlyTheIdentityIntroducedByVerifiedRegistration() throws {
        let retained = (0..<20).map { "retained-\($0)" }
        for after in [retained + ["current"], ["current"] + retained.reversed()] {
            #expect(
                try HostRemoteIdentitySelection.select(
                    before: Set(retained), after: after, verified: "retained-0") == "current")
        }
    }

    @Test func ambiguousRegistrationRejectsEvenAPreviouslyVerifiedIdentity() {
        #expect(throws: HostWorkerError.rejected) {
            try HostRemoteIdentitySelection.select(
                before: ["old"], after: ["old", "new-one", "new-two"], verified: "old")
        }
    }

    @Test func restartDoesNotChooseFromUnchangedRetainedIdentities() {
        #expect(throws: HostWorkerError.rejected) {
            try HostRemoteIdentitySelection.select(
                before: ["old", "current"], after: ["current", "old"], verified: nil)
        }
    }

    @Test func unchangedPreviouslyAuthenticatedOrUniqueIdentityStillRequiresPeerAuthentication()
        throws
    {
        #expect(
            try HostRemoteIdentitySelection.select(
                before: ["old", "current"], after: ["old", "current"], verified: "current")
                == "current")
        #expect(
            try HostRemoteIdentitySelection.select(
                before: ["only"], after: ["only"], verified: nil) == "only")
        #expect(throws: HostWorkerError.rejected) {
            try HostRemoteIdentitySelection.select(
                before: ["old", "current"], after: ["old", "current"], verified: "missing")
        }
    }

    @Test func malformedAndUnboundedIdentitySnapshotsReject() {
        for after in [
            ["same", "same"], [""], [String(repeating: "a", count: 1025)],
            (0..<65).map { "id-\($0)" }, [],
        ] {
            #expect(throws: HostWorkerError.rejected) {
                try HostRemoteIdentitySelection.select(before: [], after: after, verified: nil)
            }
        }
    }
}
