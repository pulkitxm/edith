import Foundation
import Testing

@testable import EdithKit

@Suite struct TrustedTimeTests {
    private let anchor = TrustedTime(
        lastServerTime: 1_800_000_000, wallClockAtSync: 1_800_000_000, monotonicAnchor: 100,
        bootSessionId: "boot-1")

    @Test func forwardClockIsPlausible() {
        #expect(anchor.assess(now: Date(timeIntervalSince1970: 1_800_000_100)) == .plausible)
    }

    @Test func rollbackWithinToleranceIsPlausible() {
        #expect(
            anchor.assess(now: Date(timeIntervalSince1970: 1_800_000_000 - 86_400))
                == .plausible)
    }

    @Test func rollbackBeyondToleranceIsSuspected() {
        #expect(
            anchor.assess(now: Date(timeIntervalSince1970: 1_800_000_000 - 86_401))
                == .rollbackSuspected)
    }

    @Test func recordCapturesServerAndLocalAnchors() {
        let recorded = TrustedTime.record(
            serverTime: Date(timeIntervalSince1970: 1_800_000_000),
            wallClock: Date(timeIntervalSince1970: 1_800_000_050),
            uptime: 1234.5,
            bootSessionId: "boot-2")

        #expect(recorded.lastServerTime == 1_800_000_000)
        #expect(recorded.wallClockAtSync == 1_800_000_050)
        #expect(recorded.monotonicAnchor == 1234.5)
        #expect(recorded.bootSessionId == "boot-2")
    }

    @Test func roundTripsThroughCredentialStore() throws {
        let store = InMemoryLicenseCredentialStore()

        try anchor.save(to: store)

        #expect(TrustedTime.load(from: store) == anchor)
        let raw = try #require(try store.read(.trustedTime))
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(json["lastServerTime"] as? Int64 == 1_800_000_000)
        #expect(json["bootSessionId"] as? String == "boot-1")
    }

    @Test func loadReturnsNilForMissingOrMalformedData() throws {
        let store = InMemoryLicenseCredentialStore()
        #expect(TrustedTime.load(from: store) == nil)

        try store.write("not-json", item: .trustedTime)
        #expect(TrustedTime.load(from: store) == nil)
    }

    @Test func bootSessionIdIsStableWithinBoot() {
        let first = TrustedTime.currentBootSessionId()
        #expect(first != "unknown")
        #expect(first == TrustedTime.currentBootSessionId())
    }
}
