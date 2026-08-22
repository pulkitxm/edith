import Foundation
import Testing

@testable import EdithKit

@Suite struct AttentionRepositoryTests {
    let now = Date(timeIntervalSince1970: 1_775_000_000)

    @Test func repositoryStartsEmptyAndDoesNotSeedActivity() {
        let fixture = fixture()
        defer { fixture.cleanup() }
        #expect(fixture.repository.hasEvents() == false)
        #expect(fixture.repository.events(from: .distantPast, to: .distantFuture).isEmpty)
    }

    @Test func adjacentHeartbeatsMergeAndRoundTrip() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let first = appEvent(start: now, duration: 15, name: "Xcode")
        let second = appEvent(start: now.addingTimeInterval(15), duration: 15, name: "Xcode")
        try fixture.repository.append(first)
        try fixture.repository.append(second)
        let events = fixture.repository.events(
            from: now.addingTimeInterval(-1), to: now.addingTimeInterval(60))
        #expect(events.count == 1)
        #expect(events[0].duration == 30)
    }

    @Test func corruptLinesAreSkipped() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try fixture.repository.append(appEvent(start: now, duration: 10, name: "Xcode"))
        let file = fixture.repository.eventFile(for: now)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        let events = fixture.repository.events(
            from: now.addingTimeInterval(-1), to: now.addingTimeInterval(60))
        #expect(events.count == 1)
    }

    @Test func settingsAndFocusSessionsPersist() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        var settings = fixture.repository.loadSettings()
        settings.trackingEnabled = true
        settings.privacyLevel = .detailed
        try fixture.repository.saveSettings(settings)
        #expect(fixture.repository.loadSettings() == settings)

        let started = try fixture.repository.startFocus(
            name: "Write proposal", duration: 1_500, now: now)
        #expect(fixture.repository.activeFocus() == started)
        let ended = try fixture.repository.endFocus(now: now.addingTimeInterval(900))
        #expect(ended.endedAt == now.addingTimeInterval(900))
        #expect(fixture.repository.activeFocus() == nil)
        #expect(
            fixture.repository.focusSessions(
                from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1_000)
            ).count == 1)
    }

    @Test func existingSettingsEnableTheMasterSwitchWhenACollectorWasActive() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let encoded = try JSONEncoder().encode(
            AttentionSettings(isEnabled: true, trackingEnabled: true))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "enabled")
        try FileManager.default.createDirectory(
            at: fixture.repository.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(
            to: fixture.repository.settingsFile)
        let settings = fixture.repository.loadSettings()
        #expect(settings.isEnabled)
        #expect(settings.trackingEnabled)
    }

    @Test func browserDetailReplacesEnclosingBrowserWithoutDoubleCounting() {
        let settings = AttentionSettings()
        let events = [
            AttentionEvent(
                startedAt: now, duration: 60, source: .application, appName: "Google Chrome",
                bundleID: "com.google.Chrome"),
            AttentionEvent(
                startedAt: now.addingTimeInterval(10), duration: 30, source: .browser,
                appName: "Google Chrome", bundleID: "com.google.Chrome",
                url: "https://web.whatsapp.com/chat", domain: "web.whatsapp.com"),
        ]
        let summary = AttentionAnalyzer().summary(
            events: events, settings: settings, from: now,
            to: now.addingTimeInterval(60))
        #expect(summary.activeDuration == 60)
        #expect(summary.communicationDuration == 30)
        #expect(summary.entities.first { $0.name == "WhatsApp" }?.duration == 30)
        #expect(summary.entities.first { $0.name == "Google Chrome" }?.duration == 30)
    }

    @Test func idleMovieIsNotEngagedEntertainmentAndMusicRemainsVisible() {
        let settings = AttentionSettings()
        let events = [
            AttentionEvent(
                startedAt: now, duration: 120, source: .browser, presence: .idle,
                appName: "Google Chrome", bundleID: "com.google.Chrome",
                domain: "netflix.com"),
            AttentionEvent(
                startedAt: now, duration: 120, source: .media, presence: .idle,
                media: AttentionMedia(
                    title: "Nights", artist: "Frank Ocean", album: "Blonde",
                    service: "Spotify", kind: "audio", playing: true)),
        ]
        let summary = AttentionAnalyzer().summary(
            events: events, settings: settings, from: now,
            to: now.addingTimeInterval(120))
        #expect(summary.entertainmentDuration == 0)
        #expect(summary.idleDuration == 120)
        #expect(summary.music.first?.title == "Nights")
        #expect(summary.music.first?.duration == 120)
    }

    @Test func browserHistoryInventoryDeduplicatesPerProfileWithoutInventingEvents() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let first = AttentionHistoryVisit(
            url: "example.com", lastVisitedAt: now, visitCount: 2, typedCount: 1,
            profile: "Default")
        let updated = AttentionHistoryVisit(
            url: "example.com", lastVisitedAt: now.addingTimeInterval(60), visitCount: 3,
            typedCount: 1, profile: "Default")
        let otherProfile = AttentionHistoryVisit(
            url: "example.com", lastVisitedAt: now, visitCount: 1, typedCount: 0,
            profile: "Work")
        try fixture.repository.importHistory([first])
        try fixture.repository.importHistory([updated, otherProfile])
        #expect(fixture.repository.historyVisits().count == 2)
        #expect(fixture.repository.historyVisits().first?.visitCount == 3)
        #expect(fixture.repository.hasEvents() == false)
    }

    private func appEvent(start: Date, duration: TimeInterval, name: String) -> AttentionEvent {
        AttentionEvent(
            startedAt: start, duration: duration, source: .application, appName: name,
            bundleID: "com.example.\(name.lowercased())")
    }

    private func fixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-attention-tests-\(UUID().uuidString)")
        return Fixture(root: root, repository: AttentionRepository(root: root))
    }

    private struct Fixture {
        let root: URL
        let repository: AttentionRepository

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
