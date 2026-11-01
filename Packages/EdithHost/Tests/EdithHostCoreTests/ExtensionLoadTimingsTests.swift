import Foundation
import Testing

@testable import EdithHostCore

@MainActor
@Suite struct ExtensionLoadTimingsTests {
    @Test func recordsPhasesPerRoleWithLaunchOffsets() throws {
        let timings = ExtensionLoadTimings(launch: Date().addingTimeInterval(-2))
        timings.record(id: "clipboard", role: "bundles", .verify, elapsed: .milliseconds(12))
        timings.record(id: "clipboard", role: "app", .start, elapsed: .milliseconds(40))
        timings.record(id: "clipboard", role: "app", .presentation, elapsed: .milliseconds(8))
        let json = timings.json(id: "clipboard")
        let bundles = try #require(json["bundles"] as? [String: Double])
        let app = try #require(json["app"] as? [String: Double])
        #expect(bundles["verifyMs"] == 12)
        #expect(app["startMs"] == 40)
        #expect(app["presentationMs"] == 8)
        #expect((app["readyAfterLaunchMs"] ?? 0) >= 2000)
        #expect((app["presentedAfterLaunchMs"] ?? 0) >= 2000)
    }

    @Test func keepsFirstPresentationOffsetAndResetsOnRestart() throws {
        let timings = ExtensionLoadTimings(launch: Date())
        timings.record(id: "emoji", role: "app", .presentation, elapsed: .milliseconds(5))
        let first = try #require(timings.entries["emoji"]?["app"]?.presentedAfterLaunch)
        timings.record(id: "emoji", role: "app", .presentation, elapsed: .milliseconds(3))
        #expect(timings.entries["emoji"]?["app"]?.presentedAfterLaunch == first)
        #expect(timings.entries["emoji"]?["app"]?.milliseconds[.presentation] == 3)
        timings.reset(id: "emoji")
        #expect(timings.json(id: "emoji").isEmpty)
    }

    @Test func measureRecordsThrowingBodies() {
        let timings = ExtensionLoadTimings(launch: Date())
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try timings.measure(id: "jev", role: "app", .start) { throw Failure() }
        }
        #expect(timings.entries["jev"] == nil)
        let value = timings.measure(id: "jev", role: "app", .start) { 7 }
        #expect(value == 7)
        #expect(timings.entries["jev"]?["app"]?.milliseconds[.start] != nil)
    }

    @Test func processStartPrecedesNow() {
        #expect(ExtensionLoadTimings.processStart() <= Date())
    }
}
