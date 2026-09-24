import CoreGraphics
import Foundation

public enum HerdrArrangement: String, CaseIterable, Codable, Sendable, Identifiable {
    case columns
    case rows
    case grid
    case tallGrid
    case focusLeft
    case focusRight
    case focusTop
    case focusBottom
    case focusCenter
    case twoColumns
    case twoRows

    public static let focusShare = 0.62

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .columns: "Side by Side"
        case .rows: "Stacked"
        case .grid: "Grid"
        case .tallGrid: "Tall Grid"
        case .focusLeft: "Focus Left"
        case .focusRight: "Focus Right"
        case .focusTop: "Focus Top"
        case .focusBottom: "Focus Bottom"
        case .focusCenter: "Focus Center"
        case .twoColumns: "Two Columns"
        case .twoRows: "Two Rows"
        }
    }

    public var minimumPanes: Int {
        switch self {
        case .columns, .rows, .focusLeft, .focusRight, .focusTop, .focusBottom: 2
        case .grid, .tallGrid, .focusCenter, .twoColumns, .twoRows: 3
        }
    }

    public func layout(_ ids: [String]) -> HerdrLayout? {
        guard ids.count >= minimumPanes else { return nil }
        let rest = Array(ids.dropFirst())
        switch self {
        case .columns:
            return .stack(.horizontal, ids)
        case .rows:
            return .stack(.vertical, ids)
        case .grid:
            return Self.grid(ids, lanes: .vertical)
        case .tallGrid:
            return Self.grid(ids, lanes: .horizontal)
        case .focusLeft:
            return .group(
                .horizontal, [.pane(ids[0]), Self.side(rest, along: .vertical)],
                ratios: [Self.focusShare, 1 - Self.focusShare])
        case .focusRight:
            return .group(
                .horizontal, [Self.side(rest, along: .vertical), .pane(ids[0])],
                ratios: [1 - Self.focusShare, Self.focusShare])
        case .focusTop:
            return .group(
                .vertical, [.pane(ids[0]), Self.side(rest, along: .horizontal)],
                ratios: [Self.focusShare, 1 - Self.focusShare])
        case .focusBottom:
            return .group(
                .vertical, [Self.side(rest, along: .horizontal), .pane(ids[0])],
                ratios: [1 - Self.focusShare, Self.focusShare])
        case .focusCenter:
            let leading = Array(rest.prefix(rest.count / 2))
            let trailing = Array(rest.dropFirst(rest.count / 2))
            return .group(
                .horizontal,
                [
                    Self.side(leading, along: .vertical), .pane(ids[0]),
                    Self.side(trailing, along: .vertical),
                ],
                ratios: [0.25, 0.5, 0.25])
        case .twoColumns:
            let split = (ids.count + 1) / 2
            return .group(
                .horizontal,
                [
                    .stack(.vertical, Array(ids.prefix(split))),
                    .stack(.vertical, Array(ids.dropFirst(split))),
                ])
        case .twoRows:
            let split = (ids.count + 1) / 2
            return .group(
                .vertical,
                [
                    .stack(.horizontal, Array(ids.prefix(split))),
                    .stack(.horizontal, Array(ids.dropFirst(split))),
                ])
        }
    }

    public static func options(for count: Int) -> [HerdrArrangement] {
        let slots = placeholders(count)
        var kept: [(HerdrArrangement, HerdrLayout)] = []
        for arrangement in allCases {
            guard let layout = arrangement.layout(slots) else { continue }
            if kept.contains(where: { $0.1.geometryMatches(layout, tolerance: 0.001) }) {
                continue
            }
            kept.append((arrangement, layout))
        }
        return kept.map(\.0)
    }

    public static func matching(_ layout: HerdrLayout) -> HerdrArrangement? {
        let count = layout.paneCount
        return options(for: count).first { arrangement in
            guard let candidate = arrangement.layout(placeholders(count)) else { return false }
            return candidate.geometryMatches(layout)
        }
    }

    public static func placeholders(_ count: Int) -> [String] {
        (0..<max(0, count)).map(String.init)
    }

    public func slotOrder(of layout: HerdrLayout) -> [String]? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let slots = slotFrames(count: layout.paneCount, in: unit, gap: 0)
        guard slots.count == layout.paneCount else { return nil }
        let frames = layout.frames(in: unit)
        var order: [String] = []
        for slot in slots {
            guard
                let match = frames.first(where: { entry in
                    !order.contains(entry.key)
                        && abs(entry.value.minX - slot.minX) < 0.01
                        && abs(entry.value.minY - slot.minY) < 0.01
                        && abs(entry.value.width - slot.width) < 0.01
                        && abs(entry.value.height - slot.height) < 0.01
                })
            else { return nil }
            order.append(match.key)
        }
        return order
    }

    public func slotFrames(count: Int, in rect: CGRect, gap: CGFloat) -> [CGRect] {
        guard let layout = layout(Self.placeholders(count)) else { return [] }
        let frames = layout.frames(in: rect, gap: gap)
        return Self.placeholders(count).compactMap { frames[$0] }
    }

    private static func side(_ ids: [String], along axis: SplitAxis) -> HerdrLayout {
        if ids.count <= 3 { return .stack(axis, ids) }
        return grid(ids, lanes: axis == .vertical ? .horizontal : .vertical)
    }

    private static func grid(_ ids: [String], lanes: SplitAxis) -> HerdrLayout {
        let perLane = Int(Double(ids.count).squareRoot().rounded(.up))
        let inner: SplitAxis = lanes == .vertical ? .horizontal : .vertical
        let chunks = stride(from: 0, to: ids.count, by: perLane).map {
            Array(ids[$0..<min($0 + perLane, ids.count)])
        }
        return .group(lanes, chunks.map { .stack(inner, $0) })
    }
}
