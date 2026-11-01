import AppKit
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
        timings.record(id: "clipboard", role: "app", .firstFrame, elapsed: .milliseconds(30))
        let json = timings.json(id: "clipboard")
        let bundles = try #require(json["bundles"] as? [String: Double])
        let app = try #require(json["app"] as? [String: Double])
        #expect(bundles["verifyMs"] == 12)
        #expect(app["startMs"] == 40)
        #expect(app["presentationMs"] == 8)
        #expect(app["firstFrameMs"] == 30)
        #expect((app["readyAfterLaunchMs"] ?? 0) >= 2000)
        #expect((app["presentedAfterLaunchMs"] ?? 0) >= 2000)
    }

    @Test func keepsFirstPresentationOffsetAndResetsOnRestart() throws {
        let timings = ExtensionLoadTimings(launch: Date())
        timings.record(id: "emoji", role: "app", .firstFrame, elapsed: .milliseconds(5))
        let first = try #require(timings.entries["emoji"]?["app"]?.presentedAfterLaunch)
        timings.record(id: "emoji", role: "app", .firstFrame, elapsed: .milliseconds(3))
        #expect(timings.entries["emoji"]?["app"]?.presentedAfterLaunch == first)
        #expect(timings.entries["emoji"]?["app"]?.milliseconds[.firstFrame] == 3)
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

    @Test func firstFrameWaitsForWindowAndRecordsOnce() async throws {
        let timings = ExtensionLoadTimings(launch: Date())
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        timings.observeFirstFrame(id: "docs", role: "app", view: view, started: .now)
        try await Task.sleep(for: .milliseconds(50))
        #expect(timings.entries["docs"] == nil)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = view
        for _ in 0..<50 where timings.entries["docs"] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let recorded = try #require(timings.entries["docs"]?["app"]?.milliseconds[.firstFrame])
        timings.observeFirstFrame(id: "docs", role: "app", view: view, started: .now)
        try await Task.sleep(for: .milliseconds(50))
        #expect(timings.entries["docs"]?["app"]?.milliseconds[.firstFrame] == recorded)
    }

    @Test func processStartPrecedesNow() {
        #expect(ExtensionLoadTimings.processStart() <= Date())
    }
}
