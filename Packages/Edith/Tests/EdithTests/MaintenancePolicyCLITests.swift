import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct MaintenancePolicyCLITests {
    @Test func policyRoundTripUsesATemporaryFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let persistence = AppUpdatePersistence(fileURL: file)
        _ = try MaintenancePolicyCLI.ignore(
            id: "firefox", version: "120.0", persistence: persistence)
        _ = try MaintenancePolicyCLI.exclude(
            bundleID: "com.example.App", persistence: persistence)
        let until = try MaintenancePolicyCLI.until("1d", now: Date(timeIntervalSince1970: 0))
        let snoozed = try MaintenancePolicyCLI.snooze(
            id: "firefox", until: until, persistence: persistence)
        #expect(snoozed.ignoredVersions["firefox"] == "120.0")
        #expect(snoozed.excludedBundleIDs.contains("com.example.App"))
        let cleared = try MaintenancePolicyCLI.reset(persistence: persistence)
        #expect(cleared.ignoredVersions.isEmpty)
        #expect(cleared.excludedBundleIDs.isEmpty)
        #expect(cleared.snoozedUntil.isEmpty)
    }

    @Test func customAttentionRangeIsInclusiveOfTheEndDay() throws {
        let interval = try AttentionCLI.customInterval(from: "2026-09-01", to: "2026-09-01")
        #expect(interval.duration == 86_400)
        #expect(throws: CLIFailure.self) {
            try AttentionCLI.customInterval(from: "2026-09-02", to: "2026-09-01")
        }
        #expect(AttentionCLI.csv("a,b") == "\"a,b\"")
    }
}
