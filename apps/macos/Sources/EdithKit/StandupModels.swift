import Foundation

public struct StandupSettings: Equatable {
    public var enabled = false
    public var scheduleHour = 9
    public var scheduleMinute = 30
    public var repoRoots: [String] = []
    public var authorEmail = ""
    public var notionDatabaseID = ""
    public var notionTagsProperty = "Tags"
    public var notionDateProperty = "Completed"
    public var workTag = "work"
    public var model = "haiku"
    public var deliverNotification = true
    public var deliverFile = true
    public var githubAllowlist: [String] = []

    public init() {}

    public var scheduleMinutesFromMidnight: Int { scheduleHour * 60 + scheduleMinute }

    public static func fromDefaults(_ d: UserDefaults = SharedDefaults.store) -> StandupSettings {
        var s = StandupSettings()
        s.enabled = d.object(forKey: "standupEnabled") as? Bool ?? false
        s.scheduleHour = d.object(forKey: "standupScheduleHour") as? Int ?? 9
        s.scheduleMinute = d.object(forKey: "standupScheduleMinute") as? Int ?? 30
        s.repoRoots = Self.splitLines(d.string(forKey: "standupRepoRoots"))
        s.authorEmail = d.string(forKey: "standupAuthorEmail") ?? ""
        s.notionDatabaseID = d.string(forKey: "standupNotionDatabaseID") ?? ""
        s.notionTagsProperty = d.string(forKey: "standupNotionTagsProperty") ?? "Tags"
        s.notionDateProperty = d.string(forKey: "standupNotionDateProperty") ?? "Completed"
        s.workTag = d.string(forKey: "standupWorkTag") ?? "work"
        s.model = d.string(forKey: "standupModel") ?? "haiku"
        s.deliverNotification = d.object(forKey: "standupDeliverNotification") as? Bool ?? true
        s.deliverFile = d.object(forKey: "standupDeliverFile") as? Bool ?? true
        s.githubAllowlist = Self.splitCSV(d.string(forKey: "standupGithubAllowlist"))
        return s
    }

    public static func splitLines(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func splitCSV(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
