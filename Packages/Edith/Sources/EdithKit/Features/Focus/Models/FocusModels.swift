import EdithCore
import Foundation

public enum FocusActivationOrigin: String, Codable, Sendable {
    case app
    case menuPanel
    case commandBar
    case globalShortcut
    case commandLine
    case automation
    case meeting
}

public struct FocusProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var sceneIDs: [UUID]
    public var windowLayoutSceneID: UUID?
    public var rollbackSceneIDs: [UUID]
    public var launchApplicationIDs: [String]
    public var quitApplicationIDs: [String]
    public var defaultDurationMinutes: Int?
    public var focusModeName: String?
    public var excludedBundleIdentifiers: Set<String>
    public var shortcut: AutomationShortcut?
    public var notifies: Bool

    public init(
        id: UUID = UUID(), name: String, isEnabled: Bool = true, sceneIDs: [UUID] = [],
        windowLayoutSceneID: UUID? = nil, rollbackSceneIDs: [UUID] = [],
        launchApplicationIDs: [String] = [], quitApplicationIDs: [String] = [],
        defaultDurationMinutes: Int? = nil, focusModeName: String? = nil,
        excludedBundleIdentifiers: Set<String> = [], shortcut: AutomationShortcut? = nil,
        notifies: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sceneIDs = sceneIDs
        self.windowLayoutSceneID = windowLayoutSceneID
        self.rollbackSceneIDs = rollbackSceneIDs
        self.launchApplicationIDs = launchApplicationIDs
        self.quitApplicationIDs = quitApplicationIDs
        self.defaultDurationMinutes = defaultDurationMinutes
        self.focusModeName = focusModeName
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.shortcut = shortcut
        self.notifies = notifies
    }
}

public struct FocusMeetingConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var profileID: UUID?
    public var startSceneIDs: [UUID]
    public var endSceneIDs: [UUID]
    public var excludedCalendarIdentifiers: Set<String>
    public var excludedTitleTerms: Set<String>
    public var minimumDurationMinutes: Int
    public var requiresJoinLink: Bool
    public var busyEventsOnly: Bool

    public init(
        isEnabled: Bool = false, profileID: UUID? = nil, startSceneIDs: [UUID] = [],
        endSceneIDs: [UUID] = [], excludedCalendarIdentifiers: Set<String> = [],
        excludedTitleTerms: Set<String> = [], minimumDurationMinutes: Int = 10,
        requiresJoinLink: Bool = false, busyEventsOnly: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.profileID = profileID
        self.startSceneIDs = startSceneIDs
        self.endSceneIDs = endSceneIDs
        self.excludedCalendarIdentifiers = excludedCalendarIdentifiers
        self.excludedTitleTerms = excludedTitleTerms
        self.minimumDurationMinutes = minimumDurationMinutes
        self.requiresJoinLink = requiresJoinLink
        self.busyEventsOnly = busyEventsOnly
    }
}

public struct FocusDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var profiles: [FocusProfile]
    public var meeting: FocusMeetingConfiguration
    public var showsStatusItem: Bool

    public init(
        version: Int = 1, profiles: [FocusProfile] = [],
        meeting: FocusMeetingConfiguration = FocusMeetingConfiguration(),
        showsStatusItem: Bool = false
    ) {
        self.version = version
        self.profiles = profiles
        self.meeting = meeting
        self.showsStatusItem = showsStatusItem
    }
}

public struct FocusSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var profileName: String
    public var origin: FocusActivationOrigin
    public var startedAt: Date
    public var endsAt: Date?
    public var restorationScene: AutomationScene
    public var rollbackSceneIDs: [UUID]
    public var meetingEndSceneIDs: [UUID]
    public var meetingEventIdentifier: String?

    public init(
        id: UUID = UUID(), profileID: UUID, profileName: String,
        origin: FocusActivationOrigin, startedAt: Date = Date(), endsAt: Date? = nil,
        restorationScene: AutomationScene, rollbackSceneIDs: [UUID] = [],
        meetingEndSceneIDs: [UUID] = [], meetingEventIdentifier: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.origin = origin
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.restorationScene = restorationScene
        self.rollbackSceneIDs = rollbackSceneIDs
        self.meetingEndSceneIDs = meetingEndSceneIDs
        self.meetingEventIdentifier = meetingEventIdentifier
    }
}

public enum FocusHistoryOutcome: String, Codable, Sendable {
    case completed
    case failed
    case recovered
}

public struct FocusHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var profileName: String
    public var origin: FocusActivationOrigin
    public var startedAt: Date
    public var endedAt: Date
    public var outcome: FocusHistoryOutcome
    public var detail: String?

    public init(
        id: UUID = UUID(), sessionID: UUID, profileName: String,
        origin: FocusActivationOrigin, startedAt: Date, endedAt: Date = Date(),
        outcome: FocusHistoryOutcome, detail: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.profileName = profileName
        self.origin = origin
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.detail = detail
    }
}

public struct FocusMeetingCandidate: Equatable, Sendable {
    public let title: String
    public let calendarIdentifier: String
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let isBusy: Bool
    public let hasJoinLink: Bool

    public init(
        title: String, calendarIdentifier: String, startsAt: Date, endsAt: Date,
        isAllDay: Bool, isBusy: Bool, hasJoinLink: Bool
    ) {
        self.title = title
        self.calendarIdentifier = calendarIdentifier
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.isBusy = isBusy
        self.hasJoinLink = hasJoinLink
    }
}

public enum FocusMeetingPolicy {
    public static func includes(
        _ event: FocusMeetingCandidate, configuration: FocusMeetingConfiguration
    ) -> Bool {
        guard configuration.isEnabled, !event.isAllDay, event.endsAt > event.startsAt else {
            return false
        }
        guard
            event.endsAt.timeIntervalSince(event.startsAt)
                >= Double(
                    max(1, configuration.minimumDurationMinutes) * 60)
        else { return false }
        guard !configuration.busyEventsOnly || event.isBusy else { return false }
        guard !configuration.requiresJoinLink || event.hasJoinLink else { return false }
        guard !configuration.excludedCalendarIdentifiers.contains(event.calendarIdentifier) else {
            return false
        }
        return !configuration.excludedTitleTerms.contains { term in
            !term.isEmpty && event.title.localizedCaseInsensitiveContains(term)
        }
    }
}

public enum FocusProfileOperation: String, CaseIterable, Sendable {
    case list
    case status
    case start
    case stop
    case history

    public var descriptor: UserOperationDescriptor {
        let effect: UserOperationEffect =
            switch self {
            case .list, .status, .history: .read
            case .start, .stop: .interactive
            }
        return UserOperationDescriptor(
            id: UserOperationID(rawValue: "focus.\(rawValue)"), summary: summary,
            cli: ["focus", rawValue == "list" ? "ls" : rawValue], effect: effect)
    }

    private var summary: String {
        switch self {
        case .list: "List configured focus profiles."
        case .status: "Show the active focus session."
        case .start: "Start a focus profile."
        case .stop: "End the active focus session and restore state."
        case .history: "Show recent focus sessions."
        }
    }
}
