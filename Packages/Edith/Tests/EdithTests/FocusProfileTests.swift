import Foundation
import Testing

@testable import EdithKit

@Suite struct FocusProfileTests {
    @Test func documentAndSessionRoundTrip() throws {
        let scene = AutomationScene(
            name: "Restore", actions: [AutomationAction(operationID: "config.set")])
        let profile = FocusProfile(
            name: "Deep work", sceneIDs: [UUID()], windowLayoutSceneID: UUID(),
            rollbackSceneIDs: [UUID()], launchApplicationIDs: ["com.apple.Safari"],
            quitApplicationIDs: ["com.apple.Music"], defaultDurationMinutes: 50,
            focusModeName: "Work", excludedBundleIdentifiers: ["com.apple.FinalCut"])
        let document = FocusDocument(
            profiles: [profile],
            meeting: FocusMeetingConfiguration(isEnabled: true, profileID: profile.id),
            showsStatusItem: true)
        let session = FocusSession(
            profileID: profile.id, profileName: profile.name, origin: .meeting,
            restorationScene: scene, rollbackSceneIDs: profile.rollbackSceneIDs,
            meetingEventIdentifier: "event")

        #expect(
            try JSONDecoder().decode(FocusDocument.self, from: JSONEncoder().encode(document))
                == document)
        #expect(
            try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(session))
                == session)
    }

    @Test func meetingPolicyHonorsPrivacyFilters() {
        let now = Date()
        let candidate = FocusMeetingCandidate(
            title: "Weekly planning", calendarIdentifier: "work", startsAt: now,
            endsAt: now.addingTimeInterval(1800), isAllDay: false, isBusy: true,
            hasJoinLink: true)
        var configuration = FocusMeetingConfiguration(isEnabled: true)
        #expect(FocusMeetingPolicy.includes(candidate, configuration: configuration))

        configuration.excludedTitleTerms = ["planning"]
        #expect(!FocusMeetingPolicy.includes(candidate, configuration: configuration))
        configuration.excludedTitleTerms = []
        configuration.excludedCalendarIdentifiers = ["work"]
        #expect(!FocusMeetingPolicy.includes(candidate, configuration: configuration))
        configuration.excludedCalendarIdentifiers = []
        configuration.minimumDurationMinutes = 45
        #expect(!FocusMeetingPolicy.includes(candidate, configuration: configuration))
    }

    @Test func storageBacksUpDocumentAndBoundsLocalHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FocusStorage(root: root, historyLimit: 2, historyMaxAge: 600)
        let profile = FocusProfile(name: "Writing")
        let document = FocusDocument(profiles: [profile])
        try storage.save(document)
        #expect(try storage.load() == document)

        let session = FocusSession(
            profileID: profile.id, profileName: profile.name, origin: .app,
            restorationScene: AutomationScene(name: "Restore", actions: []))
        try storage.saveSession(session)
        #expect(try storage.session() == session)
        try storage.saveSession(nil)
        #expect(try storage.session() == nil)

        for index in 0..<3 {
            try storage.append(
                FocusHistoryRecord(
                    sessionID: UUID(), profileName: profile.name, origin: .app,
                    startedAt: Date().addingTimeInterval(Double(index)), outcome: .completed))
        }
        #expect(try storage.history().count == 2)
    }
}
