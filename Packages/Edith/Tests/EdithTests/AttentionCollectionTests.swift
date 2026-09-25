import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AttentionCollectionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func host(_ agents: [HerdrAgent], reachable: Bool = true) -> HerdrHostSnapshot {
        HerdrHostSnapshot(
            id: "tuf", name: "tuf", isLocal: false, herdrPresent: true, reachable: reachable,
            agents: agents)
    }

    private func agent(
        _ pane: String, status: HerdrAgentStatus, kind: String = "codex",
        category: HerdrPaneCategory = .agent
    ) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "tuf", machineName: "tuf", machineIsLocal: false, sshTarget: "tuf",
            session: "s", pane: pane, kind: kind, status: status, title: "Fix the build",
            workspace: "w", cwd: "/home/me/src/edith", category: category)
    }

    @Test func workingAgentsBecomeGrowingSegmentsThatFlushWhenTheyStop() {
        var recorder = AttentionAgentRecorder()
        #expect(recorder.observe([host([agent("1", status: .working)])], now: now).isEmpty)
        let second = recorder.observe(
            [host([agent("1", status: .working)])], now: now.addingTimeInterval(30))
        #expect(second.count == 1)
        #expect(second.first?.duration == 30)
        #expect(second.first?.tag(AttentionTag.agent) == "Codex")
        #expect(second.first?.tag(AttentionTag.project) == "edith")
        #expect(second.first?.tag(AttentionTag.machine) == "tuf")
        #expect(second.first?.isSegment == true)
        #expect(
            recorder.observe([host([agent("1", status: .working)])], now: now.addingTimeInterval(40))
                .isEmpty)
        let stopped = recorder.observe(
            [host([agent("1", status: .idle)])], now: now.addingTimeInterval(45))
        #expect(stopped.count == 1)
        #expect(stopped.first?.id == second.first?.id)
        #expect(stopped.first?.duration == 40)
    }

    @Test func terminalsAndUnreachableHostsAreNeverCreditedAsAgentWork() {
        var recorder = AttentionAgentRecorder()
        _ = recorder.observe(
            [host([agent("t", status: .working, category: .terminal)])], now: now)
        #expect(
            recorder.observe(
                [host([agent("t", status: .working, category: .terminal)])],
                now: now.addingTimeInterval(30)
            ).isEmpty)
        _ = recorder.observe([host([agent("1", status: .working)], reachable: false)], now: now)
        #expect(
            recorder.observe(
                [host([agent("1", status: .working)], reachable: false)],
                now: now.addingTimeInterval(30)
            ).isEmpty)
    }

    @Test func blockedTimeIsASeparateSegment() {
        var recorder = AttentionAgentRecorder()
        _ = recorder.observe([host([agent("1", status: .working)])], now: now)
        let working = recorder.observe(
            [host([agent("1", status: .blocked)])], now: now.addingTimeInterval(30))
        #expect(working.map { $0.tag(AttentionTag.status) } == [])
        let blocked = recorder.observe(
            [host([agent("1", status: .blocked)])], now: now.addingTimeInterval(60))
        #expect(blocked.first?.tag(AttentionTag.status) == "blocked")
        #expect(blocked.first?.duration == 30)
    }

    @Test func heartbeatsCarryTagsSignalsAndAudibleTabs() {
        let heartbeat = AttentionBrowserHeartbeat(
            timestamp: now, duration: 20, presence: .active, appName: "Chrome",
            url: "https://github.com/pulkit/edith/pull/12?diff=split", title: "Pull request",
            tags: ["repo": "pulkit/edith", "github": "pull", "search": "attention"],
            signals: AttentionSignals(keys: 12, clicks: 3, scrolls: 40, tabs: 18),
            audible: [
                AttentionAudibleTab(
                    timestamp: now, duration: 20, title: "Lofi radio",
                    url: "https://music.youtube.com/watch?v=1")
            ])
        let detailed = AttentionIngestionServer.events(from: heartbeat, privacyLevel: .detailed)
        #expect(detailed.count == 2)
        #expect(detailed[0].tag("repo") == "pulkit/edith")
        #expect(detailed[0].tag("search") == "attention")
        #expect(detailed[0].signals?.tabs == 18)
        #expect(detailed[1].source == .media)
        #expect(detailed[1].media?.title == "Lofi radio")
        #expect(detailed[1].domain == "music.youtube.com")
        #expect(detailed[1].isSegment)
        let domains = AttentionIngestionServer.events(from: heartbeat, privacyLevel: .domains)
        #expect(domains[0].tag("search") == nil)
        #expect(domains[0].tag("repo") == "pulkit/edith")
        #expect(domains[1].media?.title == "music.youtube.com")
    }

    @Test func segmentUpsertsKeepTheLongestVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionSegments.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentStore(url: root.appendingPathComponent("store.sqlite"), build: "test")
        let events = AttentionEventStore(store: store)
        func segment(_ duration: TimeInterval) -> AttentionEvent {
            AttentionEvent(
                id: "agent:x:1", startedAt: now, duration: duration, source: .agent,
                tags: ["machine": "tuf"])
        }
        try events.record(AttentionBatch(events: [segment(30)]), now: now)
        try events.record(AttentionBatch(events: [segment(90)]), now: now)
        try events.record(AttentionBatch(events: [segment(60)]), now: now)
        let stored = try events.events(from: now, to: now.addingTimeInterval(200))
        #expect(stored.count == 1)
        #expect(stored.first?.duration == 90)
    }

    @Test func playbackParsersReadPlayersAndEdith() {
        let spotify = AttentionPlaybackParser.external(
            service: "Spotify", bundleID: "com.spotify.client",
            userInfo: ["Player State": "Playing", "Name": "Song", "Artist": "Band"])
        #expect(spotify?.media.artist == "Band")
        #expect(
            AttentionPlaybackParser.external(
                service: "Spotify", bundleID: "com.spotify.client",
                userInfo: ["Player State": "Paused", "Name": "Song"]) == nil)
        let edith = AttentionPlaybackParser.edith(
            ["track": "Focus/Deep Work.mp3", "isPlaying": true, "duration": 200.0, "elapsed": 50.0],
            now: now)
        #expect(edith?.media.title == "Deep Work")
        #expect(edith?.media.album == "Focus")
        #expect(edith?.expiresAt == now.addingTimeInterval(180))
    }

    @Test func inputCountersBecomeSignalsAndIgnoreWraparound() {
        let before = AttentionInputCounters(keys: 10, clicks: 5, scrolls: 100)
        let after = AttentionInputCounters(keys: 25, clicks: 4, scrolls: 160)
        let signals = after.signals(since: before)
        #expect(signals.keys == 15)
        #expect(signals.clicks == 0)
        #expect(signals.scrolls == 60)
    }

    @MainActor @Test func mediaSegmentsGrowWhilePlaying() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = AttentionCollectedEvents()
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: root.appendingPathComponent("delivery.json")),
            prepare: { $0.event }, deliver: { await recorded.append($0.batch.events) })
        let service = AttentionTrackingService(
            repository: AttentionRepository(root: root), writer: writer,
            settings: AttentionSettings(isEnabled: true, trackingEnabled: true), observe: false,
            now: now
        ) { _, _, _ in nil }
        let track = AttentionPlayback(
            media: AttentionMedia(title: "Song", service: "Spotify", kind: "audio", playing: true))
        service.recordMedia(now: now, playing: [track])
        service.recordMedia(now: now.addingTimeInterval(5), playing: [track])
        await writer.flush()
        let events = await recorded.events
        #expect(Set(events.map(\.id)).count == 1)
        #expect(events.last?.duration == 5)
        #expect(events.last?.media?.title == "Song")
        await service.shutdown().value
    }
}

private actor AttentionCollectedEvents {
    var events: [AttentionEvent] = []
    func append(_ batch: [AttentionEvent]) { events += batch }
}
