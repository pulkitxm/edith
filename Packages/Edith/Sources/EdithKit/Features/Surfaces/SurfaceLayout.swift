import Foundation

public enum SurfaceTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case home, notch
    public var id: String { rawValue }
    public var title: String { self == .home ? "Home" : "Notch" }
    public var key: String { "surfaceGrid.\(rawValue)" }
}

public enum SurfaceWidget: Codable, RawRepresentable, CaseIterable, Hashable, Identifiable, Sendable
{
    case clocks, actions, activity, usage, limits, music, calendar, codeStats
    case agents, focus, databases, machines, desk, media, github
    case ability(String)

    public static let core: [Self] = [
        .clocks, .actions, .activity, .usage, .limits, .music, .calendar, .codeStats,
        .agents, .focus, .databases, .machines, .desk, .media, .github,
    ]
    public static var allCases: [Self] {
        core
            + ExtensionRegistry.entries.filter { !representedAbilities.contains($0.id) }
            .map { .ability($0.id) }
    }
    private static let representedAbilities: Set<String> = [
        "usage", "herdr", "music", "calendar", "codeStats", "database",
    ]
    public var rawValue: String {
        switch self {
        case .ability(let id): "extension:" + id
        default: String(describing: self)
        }
    }
    public init?(rawValue: String) {
        if let value = Self.core.first(where: { $0.rawValue == rawValue }) {
            self = value
        } else if rawValue.hasPrefix("extension:"),
            ExtensionRegistry.entry(String(rawValue.dropFirst(10))) != nil
        {
            self = .ability(String(rawValue.dropFirst(10)))
        } else {
            return nil
        }
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown widget")
        }
        self = value
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var registryEntry: ExtensionRegistryEntry? {
        switch self {
        case .ability(let id): ExtensionRegistry.entry(id)
        case .activity, .usage, .limits: ExtensionRegistry.entry("usage")
        case .agents: ExtensionRegistry.entry("herdr")
        case .music: ExtensionRegistry.entry("music")
        case .calendar: ExtensionRegistry.entry("calendar")
        case .codeStats: ExtensionRegistry.entry("codeStats")
        case .databases: ExtensionRegistry.entry("database")
        default: nil
        }
    }
    public var suite: SuiteID? {
        if let entry = registryEntry { return entry.suite }
        return switch self {
        case .github: .agents
        case .focus: .data
        case .machines: .system
        case .desk, .clocks: .desk
        case .media: .media
        case .actions: .system
        default: nil
        }
    }

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
        case .ability: registryEntry?.title ?? "Extension"
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
        case .ability: registryEntry?.symbolName ?? "puzzlepiece.extension"
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
        case .databases: "Connections, saved queries, and recent operation outcomes."
        case .machines: "Registered machines and fleet access."
        case .desk: "Clipboard, color picker, and file tools."
        case .media: "Recording, downloads, camera, and music."
        case .github: "Pull requests, reviews, and checks from GitHub."
        case .ability: registryEntry?.subtitle ?? ""
        }
    }
    public var destination: String {
        switch self {
        case .clocks, .actions: "home"
        case .activity, .usage, .limits: "dashboard"
        case .music: "music"
        case .calendar: "calendar"
        case .codeStats: "codeStats"
        case .github: "quinjet"
        case .agents: "herdr"
        case .focus: "attention"
        case .databases: "database"
        case .machines: "machines"
        case .desk: "desk"
        case .media: "media"
        case .ability(let id): id
        }
    }
    public var gate: String? {
        switch self {
        case .activity, .usage, .limits: AppStorageKeys.Tabs.usageEnabled
        case .music: AppStorageKeys.Tabs.musicEnabled
        case .calendar: AppStorageKeys.Tabs.calendarEnabled
        case .codeStats: AppStorageKeys.Tabs.codeStatsEnabled
        case .ability: registryEntry?.defaultsKey
        case .databases: AppStorageKeys.Tabs.databaseEnabled
        default: nil
        }
    }
    public func available(in defaults: UserDefaults) -> Bool {
        guard gate.map({ defaults.bool(forKey: $0) }) ?? true else { return false }
        return registryEntry?.requires.allSatisfy { id in
            ExtensionRegistry.entry(id).map { defaults.bool(forKey: $0.defaultsKey) } ?? false
        } ?? true
    }
}

public struct SurfaceTile: Codable, Equatable, Identifiable, Sendable {
    public var widget: SurfaceWidget
    public var instanceID: String
    public var locked = false
    public var title = ""
    public var hidden = false
    public var focusMinutes = 25
    public var days = 30
    public var span = 12
    public var column: Int?
    public var row: Int?
    public var height: Double?
    public var showTitle = true
    public var showDetails = true
    public var showActions = true
    public var itemLimit = 5
    public var dense = false
    public var accent = true
    public var hiddenFields: Set<String> = []
    public var paddingOverride: Double?
    public var cornerOverride: Double?
    public var shelfWidth: Double?
    public var sourceIDs: Set<String>?
    public var contentKinds: Set<String>?
    public var agentPhases: Set<String>?
    public var includeSubagents = true
    public var id: String { instanceID }
    public var displayTitle: String {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? widget.title : label
    }

    public init(_ widget: SurfaceWidget) {
        self.widget = widget
        instanceID = widget.rawValue
        if widget == .agents { hiddenFields = ["quiet", "errors", "subagents", "model", "source"] }
    }

    public func shows(_ field: String) -> Bool { !hiddenFields.contains(field) }
}

public struct SurfaceLayout: Codable, Equatable, Sendable {
    public static let maximumColumns = 192
    public static let maximumRow = 100_000
    public static let maximumTiles = 200
    public var tiles: [SurfaceTile]
    public var tabOrder: [String] = SurfaceNotchTab.allCases.map(\.rawValue)
    public var hiddenTabs: [String] = []
    public var columns = 24
    public var gap = 12.0
    public var padding = 16.0
    public var cornerRadius = 14.0
    public var rowHeight = 8.0
    public var notchCardWidth = 280.0
    public var notchHorizontal = true
    public var notchWidth = 580.0
    public var notchShelfHeight = 240.0
    public var notchLeadingGlance = SurfaceGlanceSource.automatic
    public var notchTrailingGlance = SurfaceGlanceSource.automatic
    public var notchWingWidth = 76.0
    public var notchIncludeSubagents = true
    public var notchAgentSources: Set<String>?
    public var notchPrioritizePermissions = true
    public var notchExpandPermissions = false
    public var visible: [SurfaceTile] { tiles.filter { !$0.hidden } }
    public init(tiles: [SurfaceTile]) { self.tiles = tiles }

    public static func standard(_ target: SurfaceTarget) -> Self {
        let widgets: [SurfaceWidget] =
            target == .home
            ? [.clocks, .actions, .activity, .calendar, .usage, .limits, .music, .codeStats]
            : [.music, .limits, .actions]
        return Self(
            tiles: widgets.map { widget in
                var tile = SurfaceTile(widget)
                if target == .home {
                    tile.dense = widget == .clocks
                    tile.span =
                        switch widget {
                        case .clocks, .calendar, .codeStats: 8
                        case .actions, .usage: 16
                        default: 12
                        }
                }
                return tile
            })
    }

    public func normalized() -> Self {
        var seen = Set<String>()
        let columns = min(Self.maximumColumns, max(4, columns))
        var result = Self(
            tiles: tiles.prefix(Self.maximumTiles).filter { seen.insert($0.id).inserted }.map {
                var tile = $0
                tile.title = String(tile.title.prefix(64))
                tile.focusMinutes = min(180, max(1, tile.focusMinutes))
                tile.days = [7, 30, 90].contains(tile.days) ? tile.days : 30
                tile.span = min(columns, max(1, tile.span))
                tile.column = tile.column.map { min(columns - tile.span, max(0, $0)) }
                tile.row = tile.row.map { min(Self.maximumRow, max(0, $0)) }
                tile.height = tile.height.flatMap { $0.isFinite ? min(1200, max(64, $0)) : nil }
                tile.itemLimit = min(20, max(1, tile.itemLimit))
                tile.paddingOverride = tile.paddingOverride.flatMap {
                    $0.isFinite ? min(48, max(0, $0)) : nil
                }
                tile.cornerOverride = tile.cornerOverride.flatMap {
                    $0.isFinite ? min(48, max(0, $0)) : nil
                }
                tile.shelfWidth = tile.shelfWidth.flatMap {
                    $0.isFinite ? min(760, max(160, $0)) : nil
                }
                tile.sourceIDs = tile.sourceIDs.map {
                    Set($0.sorted().prefix(100).map { String($0.prefix(512)) })
                }
                tile.contentKinds = tile.contentKinds.map {
                    Set(
                        $0.filter { value in tile.widget.contentChoices.contains { $0.id == value }
                        })
                }
                tile.agentPhases = tile.agentPhases.map {
                    Set($0.filter { AgentActivityPhase(rawValue: $0) != nil })
                }
                return tile
            })
        result.columns = columns
        result.gap = gap.isFinite ? min(32, max(0, gap)) : 12
        result.padding = padding.isFinite ? min(32, max(0, padding)) : 16
        result.cornerRadius = cornerRadius.isFinite ? min(32, max(0, cornerRadius)) : 14
        result.rowHeight = rowHeight.isFinite ? min(32, max(1, rowHeight)) : 8
        result.notchCardWidth = notchCardWidth.isFinite ? min(520, max(180, notchCardWidth)) : 280
        result.notchHorizontal = notchHorizontal
        result.notchWidth = notchWidth.isFinite ? min(1200, max(440, notchWidth)) : 580
        result.notchShelfHeight =
            notchShelfHeight.isFinite ? min(600, max(160, notchShelfHeight)) : 240
        result.notchLeadingGlance = notchLeadingGlance
        result.notchTrailingGlance = notchTrailingGlance
        result.notchWingWidth = notchWingWidth.isFinite ? min(140, max(42, notchWingWidth)) : 76
        result.notchIncludeSubagents = notchIncludeSubagents
        result.notchAgentSources = notchAgentSources.map {
            Set($0.sorted().prefix(100).map { String($0.prefix(512)) })
        }
        result.notchPrioritizePermissions = notchPrioritizePermissions
        result.notchExpandPermissions = notchExpandPermissions
        let known = SurfaceNotchTab.allCases.map(\.rawValue)
        var seenTabs = Set<String>()
        result.tabOrder = (tabOrder + known).filter {
            known.contains($0) && seenTabs.insert($0).inserted
        }
        result.hiddenTabs = hiddenTabs.filter { known.contains($0) && $0 != "home" }
        return result
    }

    public mutating func place(_ widget: SurfaceWidget, before anchor: String? = nil) {
        var tile = tiles.first { $0.widget == widget } ?? SurfaceTile(widget)
        tile.hidden = false
        guard anchor != tile.id else { return }
        tiles.removeAll { $0.id == tile.id }
        let index = anchor.flatMap { id in tiles.firstIndex { $0.id == id } } ?? tiles.endIndex
        tiles.insert(tile, at: index)
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

    public mutating func resampleGrid(
        columns requestedColumns: Int? = nil, snap requestedSnap: Double? = nil
    ) {
        let previous = normalized()
        let nextColumns = min(Self.maximumColumns, max(4, requestedColumns ?? previous.columns))
        let snap = requestedSnap ?? previous.rowHeight
        let nextSnap = snap.isFinite ? min(32, max(1, snap)) : previous.rowHeight
        let scale = Double(nextColumns) / Double(previous.columns)
        self = previous
        columns = nextColumns
        rowHeight = nextSnap
        for index in tiles.indices {
            tiles[index].span = min(
                nextColumns, max(1, Int((Double(tiles[index].span) * scale).rounded())))
            tiles[index].column = tiles[index].column.map {
                min(nextColumns - tiles[index].span, max(0, Int((Double($0) * scale).rounded())))
            }
            tiles[index].row = tiles[index].row.map {
                min(
                    Self.maximumRow,
                    max(0, Int((Double($0) * previous.rowHeight / nextSnap).rounded())))
            }
        }
    }

    public mutating func arrangeAutomatically() {
        for index in tiles.indices where !tiles[index].locked {
            tiles[index].column = nil
            tiles[index].row = nil
        }
    }

    public mutating func move(_ id: String, before anchor: String?) {
        guard anchor != id, let index = tiles.firstIndex(where: { $0.id == id }),
            !tiles[index].locked
        else { return }
        let tile = tiles.remove(at: index)
        let destination =
            anchor.flatMap { anchor in tiles.firstIndex { $0.id == anchor } } ?? tiles.endIndex
        tiles.insert(tile, at: destination)
    }

    @discardableResult
    public mutating func add(_ widget: SurfaceWidget, column: Int? = nil, row: Int? = nil) -> String
    {
        guard tiles.count < Self.maximumTiles else { return tiles.last?.id ?? widget.rawValue }
        var tile = SurfaceTile(widget)
        tile.span = max(1, columns / 2)
        if tiles.contains(where: { $0.id == tile.id }) { tile.instanceID = UUID().uuidString }
        tile.column = column
        tile.row = row
        if column != nil || row != nil { position(tile) } else { tiles.append(tile) }
        return tile.id
    }

    @discardableResult
    public mutating func duplicate(_ id: String) -> String? {
        guard tiles.count < Self.maximumTiles, let index = tiles.firstIndex(where: { $0.id == id })
        else { return nil }
        var copy = tiles[index]
        copy.instanceID = UUID().uuidString
        copy.column = nil
        copy.row = nil
        copy.locked = false
        tiles.insert(copy, at: index + 1)
        return copy.id
    }

    public mutating func position(_ tile: SurfaceTile) {
        tiles.removeAll { $0.id == tile.id }
        tiles.insert(tile, at: 0)
    }
}

extension SurfaceWidget {
    public var fields: [(String, String)] {
        switch self {
        case .clocks: [("faces", "Clock faces"), ("offsets", "Time differences")]
        case .actions: [("icons", "Control icons"), ("descriptions", "Control descriptions")]
        case .usage:
            [
                ("today", "Today's totals"), ("week", "Weekly totals"), ("tokens", "Token counts"),
                ("chart", "Daily cost chart"), ("models", "Model breakdown"),
            ]
        case .limits:
            [
                ("session", "Session limits"), ("weekly", "Weekly limits"),
                ("additional", "Additional model limits"), ("remaining", "Remaining capacity"),
                ("resets", "Reset countdowns"), ("account", "Account details"),
                ("updated", "Last update"),
            ]
        case .music:
            [
                ("artwork", "Album artwork"), ("artist", "Artist name"),
                ("queue", "Upcoming tracks"), ("progress", "Playback time"),
            ]
        case .calendar: [("time", "Meeting times"), ("join", "Join meeting controls")]
        case .codeStats:
            [
                ("commits", "Commit totals"), ("lines", "Authored lines"),
                ("streak", "Current streak"), ("repositories", "Repository breakdown"),
            ]
        case .agents:
            [
                ("running", "Working count"), ("waiting", "Needs attention count"),
                ("total", "Active count"), ("stuck", "Confirmed stuck count"),
                ("quiet", "No recent signal count"), ("errors", "Error count"),
                ("subagents", "Subagent count"), ("sessions", "Session list"),
                ("approvals", "Permission requests"), ("provider", "Provider names"),
                ("tool", "Latest tool and command"), ("model", "Model name"),
                ("elapsed", "Session elapsed time"), ("source", "Source and last signal"),
            ]
        case .ability, .machines, .desk, .media, .github, .databases: extensionFields
        default: []
        }
    }
}

public struct SurfaceGridPlacement: Equatable, Sendable {
    public let column: Int
    public let row: Int
    public let span: Int
    public let rows: Int

    public init(column: Int, row: Int, span: Int, rows: Int) {
        self.column = column
        self.row = row
        self.span = span
        self.rows = rows
    }

    public func overlaps(_ other: Self) -> Bool {
        column < other.column + other.span && column + span > other.column
            && row < other.row + other.rows && row + rows > other.row
    }
}

public enum SurfaceGridPacking {
    public static func pack(
        tiles: [SurfaceTile], columns: Int, heights: [Double], rowHeight: Double, gap: Double
    ) -> [SurfaceGridPlacement] {
        let columns = min(SurfaceLayout.maximumColumns, max(1, columns))
        let unit = rowHeight.isFinite ? min(32, max(1, rowHeight)) : 8
        let spacing = Int(ceil((gap.isFinite ? min(32, max(0, gap)) : 12) / unit))
        var placed: [SurfaceGridPlacement] = []
        let ordered = tiles.enumerated().sorted { left, right in
            func priority(_ tile: SurfaceTile) -> Int {
                tile.locked ? 2 : (tile.column != nil || tile.row != nil ? 1 : 0)
            }
            let leftPriority = priority(left.element)
            let rightPriority = priority(right.element)
            return leftPriority == rightPriority
                ? left.offset < right.offset : leftPriority > rightPriority
        }
        var positions: [Int: SurfaceGridPlacement] = [:]
        for (index, tile) in ordered {
            let span = min(columns, max(1, tile.span))
            let height = tile.height ?? (heights.indices.contains(index) ? heights[index] : 100)
            let safeHeight = height.isFinite ? min(10_000, max(1, height)) : 100
            let rows = max(1, Int(ceil(safeHeight / unit))) + spacing
            let start = min(columns - span, max(0, tile.column ?? 0))
            var row = min(SurfaceLayout.maximumRow, max(0, tile.row ?? 0))
            var candidate = SurfaceGridPlacement(column: start, row: row, span: span, rows: rows)
            while true {
                let options = tile.column == nil ? Array(0...(columns - span)) : [start]
                if let column = options.first(where: { column in
                    let frame = SurfaceGridPlacement(
                        column: column, row: row, span: span, rows: rows)
                    return !placed.contains { frame.overlaps($0) }
                }) {
                    candidate = SurfaceGridPlacement(
                        column: column, row: row, span: span, rows: rows)
                    break
                }
                let blocked = placed.filter { other in
                    other.row + other.rows > row && other.row < row + rows
                        && (tile.column == nil
                            || (start < other.column + other.span && start + span > other.column))
                }
                row = blocked.map { $0.row + $0.rows }.min() ?? (row + 1)
            }
            placed.append(candidate)
            positions[index] = candidate
        }
        return tiles.indices.compactMap { positions[$0] }
    }
}
