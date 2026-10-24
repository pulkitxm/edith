import EdithKit
import Foundation

enum WorkspaceLayoutRestoration {
    static func adding(_ ids: [String], to layout: HerdrLayout) -> HerdrLayout {
        if let current = HerdrArrangement.matching(layout),
            let order = current.slotOrder(of: layout), let flowed = current.layout(order + ids)
        {
            return flowed
        }
        return ids.reduce(layout) { $0.inserting(.pane($1), atEdge: .right) }
    }

    static func restoring(_ pane: String, into current: HerdrLayout, from snapshot: HerdrLayout)
        -> HerdrLayout
    {
        guard snapshot.contains(pane), !current.contains(pane) else {
            return current.contains(pane) ? current : adding([pane], to: current)
        }
        let survivors = current.panes.filter { snapshot.contains($0) }
        guard !survivors.isEmpty else { return adding([pane], to: current) }
        let missing = snapshot.panes.filter { $0 != pane && !current.contains($0) }
        let extras = current.panes.filter { !snapshot.contains($0) }
        if missing.isEmpty, extras.isEmpty { return snapshot }
        if extras.isEmpty {
            let layout = missing.reduce(snapshot) { $0.removing($1) ?? .pane(pane) }
            return layout.contains(pane) ? layout : adding([pane], to: current)
        }
        let frames = snapshot.frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let origin = frames[pane] else { return adding([pane], to: current) }
        var best: (distance: CGFloat, side: InsertSide, neighbor: String)?
        for side in [InsertSide.left, .right, .top, .bottom] {
            guard let neighbor = snapshot.neighbor(of: pane, toward: side),
                current.contains(neighbor), let frame = frames[neighbor]
            else { continue }
            let distance =
                side.axis == .horizontal
                ? abs(frame.midX - origin.midX) : abs(frame.midY - origin.midY)
            if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (distance, side, neighbor)
            }
        }
        guard let best else { return adding([pane], to: current) }
        let towardPane: InsertSide
        switch best.side {
        case .left: towardPane = .right
        case .right: towardPane = .left
        case .top: towardPane = .bottom
        case .bottom: towardPane = .top
        }
        return current.inserting(.pane(pane), near: best.neighbor, side: towardPane)
    }
}
