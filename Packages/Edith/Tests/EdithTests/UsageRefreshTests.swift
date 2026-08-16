import EdithKit
import Foundation
import Testing

@Suite struct UsageRefreshTests {
    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-refresh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func parsesEveryEventTheScriptEmits() {
        #expect(
            UsageRefreshEvent.parse("phase\tcli\t28 days\t0.88")
                == .phase(name: "cli", detail: "28 days", seconds: 0.88))
        #expect(
            UsageRefreshEvent.parse("note\tdiscovering sources")
                == .note("discovering sources"))
        #expect(
            UsageRefreshEvent.parse("summary\tsources\tcli, codex")
                == .summary(label: "sources", value: "cli, codex"))
        #expect(
            UsageRefreshEvent.parse("error\tno usage found from any source")
                == .failure("no usage found from any source"))
        #expect(UsageRefreshEvent.parse("done\t7.80") == .finished(seconds: 7.8))
    }

    @Test func ignoresLinesThatAreNotEvents() {
        #expect(UsageRefreshEvent.parse("") == nil)
        #expect(UsageRefreshEvent.parse("some stray jq warning") == nil)
        #expect(UsageRefreshEvent.parse("phase\tcli") == nil)
        #expect(UsageRefreshEvent.parse("done") == nil)
    }

    @Test func wireLineRoundTripsThroughParse() {
        let events: [UsageRefreshEvent] = [
            .phase(name: "walk", detail: "120038 messages", seconds: 2.53),
            .note("assembling usage.json"),
            .summary(label: "spend", value: "$10.00 · 3 sessions"),
            .failure("validation failed"),
            .finished(seconds: 17.56),
        ]
        for event in events {
            #expect(UsageRefreshEvent.parse(event.wireLine) == event)
        }
    }

    @Test func transcriptMatchesTheLayoutTheAppUsedToPrint() {
        let started = Date(timeIntervalSince1970: 0)
        let text = UsageRefreshTranscript.render(
            [
                .phase(name: "ccusage", detail: "cached", seconds: 0.01),
                .note("discovering sources"),
                .summary(label: "sources", value: "cli"),
                .finished(seconds: 1.5),
            ], startedAt: started)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains { $0.hasPrefix("  EDITH · refresh usage · ") })
        #expect(lines.contains("  ▸ ccusage    cached                             0.01s"))
        #expect(lines.contains("  · discovering sources…"))
        #expect(lines.contains("  ✓ sources   cli"))
        #expect(lines.contains("  ✓ done in 1.50s"))
    }

    @Test func transcriptRulesOffTheSummaryBlockOnce() {
        let text = UsageRefreshTranscript.render(
            [
                .summary(label: "sources", value: "cli"),
                .summary(label: "spend", value: "$1.00"),
            ], startedAt: Date(timeIntervalSince1970: 0))
        let rules = text.split(separator: "\n").filter { $0.contains(UsageRefreshTranscript.rule) }
        #expect(rules.count == 2)
    }

    @Test func lockIsExclusiveAcrossHolders() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("refresh.lock")
        #expect(UsageRefreshLock.isHeld(at: url) == false)
        let held = UsageRefreshLock.acquire(at: url)
        #expect(held != nil)
        #expect(UsageRefreshLock.acquire(at: url) == nil)
        #expect(UsageRefreshLock.isHeld(at: url) == true)
        held?.release()
        #expect(UsageRefreshLock.isHeld(at: url) == false)
        #expect(UsageRefreshLock.acquire(at: url) != nil)
    }

    @Test func followerReadsEventsWrittenByAnotherProcess() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = UsageRefreshRunner.eventsURL(dataDir: dir)
        let events: [UsageRefreshEvent] = [
            .phase(name: "cli", detail: "3 days", seconds: 0.4),
            .finished(seconds: 0.9),
        ]
        try (events.map(\.wireLine).joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(UsageRefreshFollower.read(url) == events)
    }

    @Test func thePipelineShipsInsideTheKitBundle() {
        #expect(UsageRefreshRunner.scriptURL() != nil)
    }
}
