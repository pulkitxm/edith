import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageRefreshTests {
    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-refresh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func usage(period: String, source: String) throws -> Data {
        let hours: [[String: Any]] = (0..<24).map {
            ["hour": $0, "cost": 0, "tokens": 0, "bySource": [:], "byPath": [:]]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 8,
                "generatedAt": "2026-08-25T00:00:00Z",
                "sources": [source],
                "defaultSources": [source],
                "sourceMeta": [source: ["label": source]],
                "machines": [],
                "totals": [
                    "cost": 1, "tokens": 1, "inputTokens": 1, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0,
                    "bySource": [source: ["cost": 1, "tokens": 1]],
                ],
                "daily": [
                    [
                        "period": period,
                        "bySource": [
                            source: [
                                [
                                    "modelName": "model", "inputTokens": 1,
                                    "outputTokens": 0, "cacheCreationTokens": 0,
                                    "cacheReadTokens": 0, "cost": 1,
                                ]
                            ]
                        ],
                        "hours": hours,
                        "projects": [],
                    ]
                ],
                "sessions": [],
            ])
    }

    @Test(arguments: [
        UsageRefreshFailure.scriptMissing,
        .busy,
        .launchFailed("permission denied"),
        .timedOut,
        .outputLimitExceeded,
        .reported("history merge failed; previous data preserved"),
        .exited(5, "jq: error: invalid history document"),
        .exited(1, ""),
    ])
    func failuresPreserveDiagnosticsAcrossFoundationBridging(failure: UsageRefreshFailure) {
        let error: any Error = failure
        let bridged = error as NSError

        #expect(error.localizedDescription == failure.description)
        #expect(bridged.localizedDescription == failure.description)
        #expect(bridged.localizedRecoverySuggestion == failure.hint)
    }

    @Test func pipelineFailureIncludesBoundedStderrAndPersistsItOnce() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = UsageRefreshSink(dataDir: dir, startedAt: Date())
        sink.begin()
        let collector = UsageRefreshCollector(sink: sink, onEvent: { _ in })
        for index in 0..<8 {
            collector.ingestStandardError(Data("diagnostic \(index)\n".utf8))
        }
        collector.ingestStandardError(Data("jq: invalid history document".utf8))
        collector.ingestStandardOutput(Data("error\thistory merge failed".utf8))
        collector.flush()
        collector.flush()

        let failure = try #require(collector.reportedFailure)
        #expect(failure.hasPrefix("history merge failed: "))
        #expect(failure.contains("jq: invalid history document"))
        #expect(!failure.contains("diagnostic 0"))
        #expect(collector.diagnosticTail.split(separator: ";").count == 6)
        let log = try String(contentsOf: UsageRefreshRunner.logURL(dataDir: dir), encoding: .utf8)
        #expect(log.components(separatedBy: "jq: invalid history document").count == 2)
    }

    @Test func reportedFailureDoesNotDuplicateIdenticalDiagnostic() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let collector = UsageRefreshCollector(
            sink: UsageRefreshSink(dataDir: dir, startedAt: Date()), onEvent: { _ in })
        collector.ingestStandardError(Data("history merge failed\n".utf8))
        collector.ingestStandardOutput(Data("error\thistory merge failed\n".utf8))
        #expect(collector.reportedFailure == "history merge failed")
    }

    @Test func collectorSuccessWaitsForPublication() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = UsageRefreshSink(dataDir: dir, startedAt: Date())
        sink.begin()
        let collector = UsageRefreshCollector(sink: sink, onEvent: { _ in })
        collector.ingestStandardOutput(Data("phase\tlocal\t1 day\t0.2\ndone\t0.5\n".utf8))
        collector.flush()
        #expect(!collector.events.contains { $0.isTerminal })
        #expect(
            !UsageRefreshFollower.read(UsageRefreshRunner.eventsURL(dataDir: dir))
                .contains { $0.isTerminal })
        collector.complete(seconds: 0.8)
        #expect(
            UsageRefreshFollower.read(UsageRefreshRunner.eventsURL(dataDir: dir)).last
                == .finished(seconds: 0.8))
    }

    @Test func publicationFailureReplacesCollectorSuccess() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = UsageRefreshSink(dataDir: dir, startedAt: Date())
        sink.begin()
        let collector = UsageRefreshCollector(sink: sink, onEvent: { _ in })
        collector.ingestStandardOutput(Data("done\t0.5\n".utf8))
        collector.fail("publication rejected")
        let events = UsageRefreshFollower.read(UsageRefreshRunner.eventsURL(dataDir: dir))
        #expect(events == [.failure("publication rejected")])
    }

    @Test func pipelineStreamsProgressBeforePublishing() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try usage(period: "2026-09-12", source: "local")
            .write(to: dir.appendingPathComponent("fixture.json"))
        let script = dir.appendingPathComponent("collector.sh")
        try """
        printf 'phase\\tlocal\\t1 day\\t0.1\\n'
        for attempt in {1..100}; do
          test -f "$1/observed" && break
          sleep 0.02
        done
        test -f "$1/observed" || exit 9
        cp "$1/fixture.json" "$EDITH_USAGE_OUTPUT"
        printf 'done\\t0.1\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        let result = try await UsageRefreshRunner.run(
            dataDir: dir, workingDirectory: dir, script: script,
            onEvent: { event in
                if case .phase = event {
                    try? Data().write(to: dir.appendingPathComponent("observed"))
                }
            })
        #expect(result.events.last?.isTerminal == true)
        #expect(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage.json").path))
    }

    @Test func machineCollectionRunsBeforeThePublicationBaseline() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = try usage(period: "2026-09-12", source: "remote")
        let script = dir.appendingPathComponent("collector.sh")
        try """
        cp "$1/remote.json" "$EDITH_USAGE_OUTPUT"
        printf 'done\\t0.1\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        _ = try await UsageRefreshRunner.run(
            dataDir: dir, workingDirectory: dir, machinePolicy: .due, script: script,
            collectMachines: { policy, root, _ in
                #expect(policy == .due)
                try? fresh.write(to: root.appendingPathComponent("remote.json"))
                try? Data("fresh generation".utf8)
                    .write(to: root.appendingPathComponent("machines.generation"))
            })
        let published = try Data(contentsOf: dir.appendingPathComponent("usage.json"))
        let document = try #require(JSONSerialization.jsonObject(with: published) as? [String: Any])
        #expect(document["sources"] as? [String] == ["remote"])
    }

    @Test func pipelinePublicationFailureIsObservedByFollowers() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = try usage(period: "2026-09-11", source: "local")
        try previous.write(to: dir.appendingPathComponent("usage.json"))
        let script = dir.appendingPathComponent("collector.sh")
        try """
        cp "$1/usage.json" "$EDITH_USAGE_OUTPUT"
        printf 'changed' > "$1/machines.generation"
        printf 'done\\t0.1\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        await #expect(throws: UsageRefreshFailure.self) {
            try await UsageRefreshRunner.run(dataDir: dir, workingDirectory: dir, script: script)
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("usage.json")) == previous)
        await #expect(throws: UsageRefreshFailure.self) {
            try await UsageRefreshFollower.follow(dataDir: dir)
        }
        #expect(
            !UsageRefreshFollower.read(UsageRefreshRunner.eventsURL(dataDir: dir))
                .contains {
                    if case .finished = $0 { return true }; return false
                })
    }

    @Test func followerCannotReportAnOlderRunsSuccess() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await UsageRefreshPlayback.replay(events: [.finished(seconds: 1)], dataDir: dir)
        await #expect(throws: UsageRefreshFailure.self) {
            try await UsageRefreshFollower.follow(dataDir: dir, runID: "different-run")
        }
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

    @Test(arguments: ["", "{\"daily\":", "[]"])
    func stagingRejectsUndecodablePreviousUsage(previous: String) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("usage.json")
        let staged = dir.appendingPathComponent("staged.json")
        let bytes = Data(previous.utf8)
        try bytes.write(to: live)

        #expect(throws: UsageDataFileError.self) {
            try UsageRefreshRunner.stageCurrentUsage(at: staged, dataDir: dir)
        }
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: live) == bytes)
    }

    @Test(arguments: ["", "{\"daily\":", "[]"])
    func publicationRejectsUndecodablePreviousUsage(previous: String) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("usage.json")
        let staged = dir.appendingPathComponent("staged.json")
        let bytes = Data(previous.utf8)
        let fresh = try usage(period: "2026-08-24", source: "fresh")
        try bytes.write(to: live)
        try fresh.write(to: staged)

        #expect(throws: UsageDataFileError.self) {
            try UsageRefreshRunner.publish(
                stagedUsage: staged, baseline: UsageRefreshBaseline(usage: bytes, machines: nil),
                dataDir: dir)
        }
        #expect(try Data(contentsOf: live) == bytes)
        #expect(try Data(contentsOf: staged) == fresh)
    }

    @Test func missingPreviousUsageAllowsFirstRefreshPublication() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("usage.json")
        let staged = dir.appendingPathComponent("staged.json")
        let baseline = try UsageRefreshRunner.stageCurrentUsage(at: staged, dataDir: dir)
        #expect(baseline.usage == nil)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        try usage(period: "2026-08-24", source: "fresh").write(to: staged)

        try UsageRefreshRunner.publish(stagedUsage: staged, baseline: baseline, dataDir: dir)

        let published = try Data(contentsOf: live)
        #expect(UsageHistory.isValidDocument(published))
        let document = try #require(
            JSONSerialization.jsonObject(with: published) as? [String: Any])
        #expect(document["sources"] as? [String] == ["fresh"])
        #expect((document["daily"] as? [[String: Any]])?.count == 1)
    }

    @Test func publicationRetainsUnavailableMachineHistory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("usage.json")
        let staged = dir.appendingPathComponent("staged.json")
        let fresh = try usage(period: "2026-08-24", source: "fresh")
        let machine = "machine:4303dcf1-52d8-4075-ae9b-c2fd86d3821a:cli"
        let baseline = try usage(period: "2026-08-20", source: machine)
        try fresh.write(to: staged)
        try baseline.write(to: live)

        try UsageRefreshRunner.publish(
            stagedUsage: staged, baseline: UsageRefreshBaseline(usage: baseline, machines: nil),
            dataDir: dir)

        let published = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: live)) as? [String: Any])
        #expect(Set(published["sources"] as? [String] ?? []) == ["fresh", machine])
        #expect((published["daily"] as? [[String: Any]])?.count == 2)
        #expect((published["totals"] as? [String: Any])?["tokens"] as? Double == 2)
    }

    @Test func publicationRebasesAConcurrentLiveReplacement() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("usage.json")
        let staged = dir.appendingPathComponent("staged.json")
        let baseline = try usage(period: "2026-08-20", source: "old")
        let concurrent = try usage(period: "2026-08-22", source: "during")
        try usage(period: "2026-08-24", source: "fresh").write(to: staged)
        try baseline.write(to: live)
        let held = try UsageDataLock.acquire(dataDirectory: dir)
        let publication = Task.detached {
            try UsageRefreshRunner.publish(
                stagedUsage: staged,
                baseline: UsageRefreshBaseline(usage: baseline, machines: nil), dataDir: dir)
        }
        await Task.yield()
        try UsageDataFiles.write(concurrent, to: live)

        held.release()
        _ = try await publication.value
        let published = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: live)) as? [String: Any])
        #expect(Set(published["sources"] as? [String] ?? []) == ["old", "during", "fresh"])
        #expect((published["daily"] as? [[String: Any]])?.count == 3)
        #expect((published["totals"] as? [String: Any])?["tokens"] as? Double == 3)
    }

    @Test func publicationRejectsAnInvalidConcurrentLiveReplacement() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("usage.json")
        let staged = dir.appendingPathComponent("staged.json")
        let baseline = try usage(period: "2026-08-20", source: "old")
        let invalid = Data("{\"daily\":".utf8)
        try usage(period: "2026-08-24", source: "fresh").write(to: staged)
        try baseline.write(to: live)
        let held = try UsageDataLock.acquire(dataDirectory: dir)
        let publication = Task.detached {
            try UsageRefreshRunner.publish(
                stagedUsage: staged,
                baseline: UsageRefreshBaseline(usage: baseline, machines: nil), dataDir: dir)
        }
        await Task.yield()
        try invalid.write(to: live)

        held.release()
        await #expect(throws: UsageDataFileError.self) {
            try await publication.value
        }
        #expect(try Data(contentsOf: live) == invalid)
    }

    @Test func publicationRejectsMachineHistoryChangedDuringRefresh() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("usage.json")
        let staged = dir.appendingPathComponent("staged.json")
        let generation = dir.appendingPathComponent("machines.generation")
        let baseline = try usage(period: "2026-08-20", source: "old")
        try baseline.write(to: live)
        try usage(period: "2026-08-24", source: "fresh").write(to: staged)
        try Data("new-generation".utf8).write(to: generation)

        #expect(throws: UsageDataFileError.self) {
            try UsageRefreshRunner.publish(
                stagedUsage: staged,
                baseline: UsageRefreshBaseline(usage: baseline, machines: nil), dataDir: dir)
        }
        #expect(try Data(contentsOf: live) == baseline)
    }

    @Test func staleOwnedRefreshStagesAreScavengedWithoutFollowingLinks() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.json")
        let current = dir.appendingPathComponent("current.json")
        let target = dir.appendingPathComponent("target.txt")
        let link = dir.appendingPathComponent("linked.json")
        try Data("old".utf8).write(to: old)
        try Data("current".utf8).write(to: current)
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: old.path)

        UsageRefreshRunner.cleanupStaleStages(in: dir, now: now)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(try Data(contentsOf: target) == Data("preserve".utf8))
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
