import Foundation

public enum SurfaceTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case home, notch
    public var id: String { rawValue }
    public var title: String { self == .home ? "Home" : "Notch" }
    public var key: String { "surfaceLayout.\(rawValue)" }
}

public enum SurfaceWidget: String, Codable, CaseIterable, Identifiable, Sendable {
    case clocks, actions, activity, usage, limits, music, calendar, codeStats
    case agents, focus, databases, machines, desk, media, github

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .clocks: "World clocks"
        case .actions: "Quick actions"
        case .activity: "Usage activity"
        case .usage: "Agent usage"
        case .limits: "Rate limits"
        case .music: "Now playing"
        case .calendar: "Meetings"
        case .codeStats: "Code stats"
        case .agents: "Live agents"
        case .focus: "Focus timer"
        case .databases: "Databases"
        case .machines: "Machines"
        case .desk: "Desk tools"
        case .media: "Media tools"
        case .github: "GitHub activity"
        }
    }
    public var icon: String {
        switch self {
        case .clocks: "clock"
        case .actions: "bolt"
        case .activity: "chart.bar.xaxis"
        case .usage: "chart.pie"
        case .limits: "gauge.with.dots.needle.50percent"
        case .music: "music.note"
        case .calendar: "calendar"
        case .codeStats: "curlybraces"
        case .agents: "terminal"
        case .focus: "timer"
        case .databases: "externaldrive"
        case .machines: "desktopcomputer"
        case .desk: "square.grid.2x2"
        case .media: "play.rectangle"
        case .github: "point.3.connected.trianglepath.dotted"
        }
    }
    public var summary: String {
        switch self {
        case .clocks: "Local time and your favorite cities."
        case .actions: "Keep awake, presenter, and system controls."
        case .activity: "Your daily agent spending at a glance."
        case .usage: "Usage totals and recent activity."
        case .limits: "Provider limits and reset countdowns."
        case .music: "Track information and playback controls."
        case .calendar: "Upcoming meetings and calendar access."
        case .codeStats: "Commits, authored lines, and streaks."
        case .agents: "Working agents and sessions needing attention."
        case .focus: "Start and finish timed deep work sessions."
        case .databases: "Open your database workspace."
        case .machines: "Registered machines and fleet access."
        case .desk: "Clipboard, color picker, and file tools."
        case .media: "Recording, downloads, camera, and music."
        case .github: "Commit activity from your code stats mirror."
        }
    }
    public var destination: String {
        switch self {
        case .clocks, .actions: "home"
        case .activity, .usage, .limits: "dashboard"
        case .music: "music"
        case .calendar: "calendar"
        case .codeStats, .github: "codeStats"
        case .agents: "herdr"
        case .focus: "attention"
        case .databases: "database"
        case .machines: "machines"
        case .desk: "desk"
        case .media: "media"
        }
    }
    public var gate: String? {
        switch self {
        case .activity, .usage, .limits: AppStorageKeys.Tabs.usageEnabled
        case .music: AppStorageKeys.Tabs.musicEnabled
        case .calendar: AppStorageKeys.Tabs.calendarEnabled
        case .codeStats, .github: AppStorageKeys.Tabs.codeStatsEnabled
        default: nil
        }
    }
    public func available(in defaults: UserDefaults) -> Bool {
        gate.map { defaults.bool(forKey: $0) } ?? true
    }
}

public enum SurfaceWidgetSize: String, Codable, CaseIterable, Sendable {
    case compact, regular, wide
    public var title: String { rawValue.capitalized }
    public var spansRow: Bool { self == .wide }
}

public struct SurfaceTile: Codable, Equatable, Identifiable, Sendable {
    public var widget: SurfaceWidget
    public var size: SurfaceWidgetSize = .regular
    public var title = ""
    public var hidden = false
    public var focusMinutes = 25
    public var days = 30
    public var id: String { widget.rawValue }
    public var displayTitle: String { title.isEmpty ? widget.title : title }

    public init(_ widget: SurfaceWidget, size: SurfaceWidgetSize = .regular) {
        self.widget = widget
        self.size = size
    }
}

public struct SurfaceLayout: Codable, Equatable, Sendable {
    public var tiles: [SurfaceTile]
    public var tabOrder: [String] = SurfaceNotchTab.allCases.map(\.rawValue)
    public var hiddenTabs: [String] = []
    public var visible: [SurfaceTile] { tiles.filter { !$0.hidden } }
    public init(tiles: [SurfaceTile]) { self.tiles = tiles }

    public static func standard(_ target: SurfaceTarget) -> Self {
        let widgets: [SurfaceWidget] =
            target == .home
            ? [.clocks, .actions, .activity, .calendar, .usage, .limits, .music, .codeStats]
            : [.music, .limits, .actions]
        return Self(
            tiles: widgets.map {
                SurfaceTile(
                    $0,
                    size: $0 == .activity || $0 == .actions || (target == .home && $0 == .clocks)
                        ? .wide : .regular)
            })
    }

    public func normalized() -> Self {
        var seen = Set<SurfaceWidget>()
        var result = Self(
            tiles: tiles.filter { seen.insert($0.widget).inserted }.map {
                var tile = $0
                tile.title = String(
                    tile.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
                tile.focusMinutes = min(180, max(1, tile.focusMinutes))
                tile.days = [7, 30, 90].contains(tile.days) ? tile.days : 30
                return tile
            })
        let known = SurfaceNotchTab.allCases.map(\.rawValue)
        var seenTabs = Set<String>()
        result.tabOrder = (tabOrder + known).filter {
            known.contains($0) && seenTabs.insert($0).inserted
        }
        result.hiddenTabs = hiddenTabs.filter { known.contains($0) && $0 != "home" }
        return result
    }

    public mutating func place(_ widget: SurfaceWidget, before anchor: String? = nil) {
        guard anchor != widget.rawValue else { return }
        var tile = tiles.first { $0.widget == widget } ?? SurfaceTile(widget)
        tile.hidden = false
        tiles.removeAll { $0.widget == widget }
        let index = anchor.flatMap { id in tiles.firstIndex { $0.id == id } } ?? tiles.endIndex
        tiles.insert(tile, at: index)
    }

    public func rows(singleColumn: Bool) -> [[SurfaceTile]] {
        var rows: [[SurfaceTile]] = []
        for tile in visible {
            if !singleColumn, !tile.size.spansRow, let last = rows.last,
                last.count == 1, !last[0].size.spansRow
            {
                rows[rows.count - 1].append(tile)
            } else {
                rows.append([tile])
            }
        }
        return rows
    }

    public static func decode(_ raw: String?, target: SurfaceTarget) -> Self {
        guard let raw, let data = raw.data(using: .utf8),
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return standard(target) }
        return value.normalized()
    }

    public var encoded: String {
        String(data: (try? JSONEncoder().encode(normalized())) ?? Data(), encoding: .utf8) ?? ""
    }
}
