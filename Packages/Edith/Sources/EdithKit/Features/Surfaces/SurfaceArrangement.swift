import Foundation

public enum SurfaceArrangement {
    public static func rowCounts(
        count: Int, width: Double, minimumWidth: Double = 340,
        maximumColumns: Int = 3, gap: Double
    )
        -> [Int]
    {
        guard count > 0 else { return [] }
        let width = width.isFinite ? max(0, width) : 600
        let minimumWidth = minimumWidth.isFinite ? max(1, minimumWidth) : 340
        let gap = gap.isFinite ? max(0, gap) : 12
        let columns = min(
            count,
            Int(min(Double(max(1, maximumColumns)), max(1, (width + gap) / (minimumWidth + gap)))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        return (0..<rows).map { count / rows + ($0 < count % rows ? 1 : 0) }
    }

    public static func shelfWidths(
        tiles: [SurfaceTile], available: Double, preferred: Double,
        gap: Double
    ) -> [Double] {
        guard !tiles.isEmpty else { return [] }
        let available = available.isFinite ? max(160, available) : 600
        let slots = min(tiles.count, max(1, Int((available + gap) / (preferred + gap))))
        let fitted = max(160, (available - Double(slots - 1) * gap) / Double(slots))
        let fixed = tiles.compactMap(\.shelfWidth)
        let automatic = tiles.count - fixed.count
        let total =
            fixed.reduce(0, +) + Double(automatic) * preferred
            + Double(tiles.count - 1) * gap
        let shared =
            automatic > 0 && total <= available
            ? max(
                160,
                (available - fixed.reduce(0, +) - Double(tiles.count - 1) * gap)
                    / Double(automatic)) : fitted
        return tiles.map { $0.shelfWidth ?? shared }
    }
}

public enum SurfacePreset: String, CaseIterable, Identifiable, Sendable {
    case everyday, agents, media, focus
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .everyday: "Everyday"
        case .agents: "Agent workspace"
        case .media: "Media desk"
        case .focus: "Deep work"
        }
    }
    public var icon: String {
        switch self {
        case .everyday: "rectangle.3.group"
        case .agents: "terminal"
        case .media: "play.rectangle"
        case .focus: "timer"
        }
    }
    public var detail: String {
        switch self {
        case .everyday: "Music, controls, meetings and limits"
        case .agents: "Live sessions, approvals, usage and GitHub"
        case .media: "Playback, media tools and desk controls"
        case .focus: "Focus timer, music and your next meeting"
        }
    }
    public func layout(for target: SurfaceTarget) -> SurfaceLayout {
        if target == .home, self == .everyday { return .standard(.home) }
        let widgets: [SurfaceWidget] =
            switch self {
            case .everyday: [.music, .actions, .calendar, .limits]
            case .agents: [.agents, .limits, .github, .usage, .codeStats, .actions]
            case .media: [.music, .media, .actions, .desk]
            case .focus: [.focus, .music, .calendar, .actions]
            }
        var layout = SurfaceLayout(
            tiles: widgets.map { widget in
                var tile = SurfaceTile(widget)
                tile.itemLimit = widget == .agents ? 20 : 5
                if target == .notch {
                    tile.dense = true
                    tile.paddingOverride = 14
                    if widget == .agents { tile.shelfWidth = 400; tile.metricColumns = 3 }
                    if widget == .music { tile.shelfWidth = 340 }
                }
                return tile
            })
        layout.notchWidth = self == .agents ? 1080 : 960
        layout.notchShelfHeight = self == .agents ? 300 : 240
        layout.notchLeadingGlance = self == .agents ? .workingAgents : .automatic
        layout.notchTrailingGlance = self == .agents ? .permissions : .automatic
        if self == .media {
            layout.notchLeadingGlance = .music
            layout.notchTrailingGlance = .music
        } else if self == .focus {
            layout.notchLeadingGlance = .focus
        }
        layout.notchIncludeSubagents = true
        return layout.normalized()
    }
}
