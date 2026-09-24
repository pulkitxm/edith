import EdithKit
import SwiftUI

struct HerdrDragOverlay: View {
    var drag: HerdrDragCoordinator
    var store: HerdrStore
    let hideAgents: Bool

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var accent: Color { DashSkin.accent(dark) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item = drag.item {
                if let target = drag.target { preview(item, target) }
                if let bar = drag.snapBar { snapBar(bar) }
                ghost(item)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func preview(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> some View {
        let canvas = drag.geometry.canvas
        switch target {
        case .edge, .outerEdge, .center, .slot:
            if let layout = store.proposedLayout(item, target) {
                layoutPreview(
                    layout, canvas: canvas, dragged: Set(dragged(item)), target: target)
            }
        case let .tabBar(index):
            caret(index)
        case let .intoTab(id):
            if let chip = drag.geometry.chips.first(where: { $0.id == id }) {
                RoundedRectangle(cornerRadius: UIScale.pt(9))
                    .fill(accent.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(9))
                            .strokeBorder(accent, lineWidth: UIScale.pt(2))
                    }
                    .frame(width: chip.frame.width + 6, height: chip.frame.height + 6)
                    .offset(x: chip.frame.minX - 3, y: chip.frame.minY - 3)
            }
        case .newTab:
            region(canvas.insetBy(dx: 12, dy: 12), label: "Open in a New Tab")
        case .window:
            EmptyView()
        }
    }

    private func layoutPreview(
        _ layout: HerdrLayout, canvas: CGRect, dragged: Set<String>, target: HerdrDropTarget
    ) -> some View {
        let gap = UIScale.pt(6)
        let frames = layout.paneFrames(in: canvas, gap: gap)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(DashSkin.paper(dark).opacity(0.55))
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)
            ForEach(Array(frames.keys).sorted(), id: \.self) { id in
                if let frame = frames[id] {
                    let highlighted = dragged.contains(id)
                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                        .fill(
                            highlighted ? accent.opacity(0.24) : DashSkin.paper2(dark).opacity(0.7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: UIScale.pt(8))
                                .strokeBorder(
                                    highlighted ? accent : DashSkin.lineStrong(dark),
                                    style: StrokeStyle(
                                        lineWidth: UIScale.pt(highlighted ? 2 : 1),
                                        dash: highlighted ? [] : [UIScale.pt(5), UIScale.pt(4)]))
                        }
                        .overlay { paneLabel(id, highlighted: highlighted, target: target) }
                        .frame(width: max(0, frame.width), height: max(0, frame.height))
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }

    @ViewBuilder
    private func paneLabel(_ id: String, highlighted: Bool, target: HerdrDropTarget) -> some View {
        if let agent = agent(for: id) {
            VStack(spacing: UIScale.pt(5)) {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(highlighted ? 18 : 13))
                    .foregroundStyle(highlighted ? accent : DashSkin.inkSoft(dark))
                Text(hideAgents ? agent.kind : agent.title)
                    .font(
                        .system(
                            size: UIScale.pt(highlighted ? 13 : 11),
                            weight: highlighted ? .semibold : .medium)
                    )
                    .foregroundStyle(highlighted ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                    .lineLimit(1)
                if highlighted, let hint = hint(target) {
                    Text(hint)
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
            .padding(UIScale.pt(8))
        }
    }

    private func hint(_ target: HerdrDropTarget) -> String? {
        switch target {
        case .edge: "Split here"
        case .outerEdge: "Span the whole side"
        case .center:
            drag.item.map { dragged($0).allSatisfy { store.session($0) != nil } } == true
                ? "Swap places" : "Replace, the other agent gets its own tab"
        case let .slot(template, _): template.title
        case .tabBar, .intoTab, .newTab, .window: nil
        }
    }

    private func caret(_ index: Int) -> some View {
        let chips = drag.geometry.chips.filter { $0.id != HerdrStore.boardID }
        let board = drag.geometry.chips.first { $0.id == HerdrStore.boardID }
        let reference = index < chips.count ? chips[index].frame : (chips.last ?? board)?.frame
        let x: CGFloat =
            index < chips.count
            ? (reference?.minX ?? 0) - UIScale.pt(4) : (reference?.maxX ?? 0) + UIScale.pt(4)
        let frame = reference ?? .zero
        return Capsule()
            .fill(accent)
            .frame(width: UIScale.pt(3), height: frame.height + UIScale.pt(6))
            .offset(x: x - UIScale.pt(1.5), y: frame.minY - UIScale.pt(3))
    }

    private func region(_ rect: CGRect, label: String) -> some View {
        RoundedRectangle(cornerRadius: UIScale.pt(12))
            .fill(accent.opacity(0.12))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(12))
                    .strokeBorder(
                        accent,
                        style: StrokeStyle(
                            lineWidth: UIScale.pt(2), dash: [UIScale.pt(7), UIScale.pt(5)]))
            }
            .overlay {
                Text(label)
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private func snapBar(_ bar: HerdrSnapBar) -> some View {
        if bar.expanded {
            let hovered: (HerdrLayoutTemplate, Int)? = {
                if case let .slot(template, index) = drag.target { return (template, index) }
                return nil
            }()
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIScale.pt(12))
                    .fill(DashSkin.paper2(dark))
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(12))
                            .strokeBorder(DashSkin.lineStrong(dark), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 16, y: 6)
                    .frame(width: bar.frame.width, height: bar.frame.height)
                    .offset(x: bar.frame.minX, y: bar.frame.minY)
                ForEach(bar.thumbnails, id: \.template.id) { thumbnail in
                    thumbnailView(
                        thumbnail,
                        hoveredSlot: hovered?.0 == thumbnail.template ? hovered?.1 : nil)
                }
            }
        } else {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                Text("Layouts")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                Image(systemName: "chevron.up")
                    .font(.system(size: UIScale.pt(8), weight: .bold))
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
            .frame(width: bar.frame.width, height: bar.frame.height)
            .background(DashSkin.paper2(dark), in: Capsule())
            .overlay { Capsule().strokeBorder(DashSkin.lineStrong(dark), lineWidth: 1) }
            .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 10, y: 4)
            .offset(x: bar.frame.minX, y: bar.frame.minY)
        }
    }

    private func thumbnailView(_ thumbnail: HerdrSnapThumbnail, hoveredSlot: Int?) -> some View {
        let frame = thumbnail.frame
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .fill(DashSkin.paper(dark))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(7))
                        .strokeBorder(
                            hoveredSlot == nil ? DashSkin.line(dark) : accent.opacity(0.8),
                            lineWidth: hoveredSlot == nil ? 1 : UIScale.pt(1.4))
                }
                .frame(width: frame.width, height: frame.height)
            ForEach(Array(thumbnail.slots.enumerated()), id: \.offset) { index, slot in
                RoundedRectangle(cornerRadius: UIScale.pt(2))
                    .fill(
                        index == hoveredSlot
                            ? accent.opacity(0.9) : DashSkin.ink(dark).opacity(0.17)
                    )
                    .frame(width: max(0, slot.width), height: max(0, slot.height))
                    .offset(x: slot.minX - frame.minX, y: slot.minY - frame.minY)
            }
            HStack(spacing: UIScale.pt(2)) {
                if thumbnail.template.isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: UIScale.pt(7)))
                        .foregroundStyle(accent)
                }
                Text(thumbnail.template.title)
            }
            .font(
                .system(size: UIScale.pt(9), weight: hoveredSlot == nil ? .medium : .semibold)
            )
            .foregroundStyle(hoveredSlot == nil ? DashSkin.inkFaint(dark) : DashSkin.ink(dark))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: frame.width)
            .offset(y: frame.height + UIScale.pt(2))
        }
        .offset(x: frame.minX, y: frame.minY)
    }

    private func ghost(_ item: HerdrDragItem) -> some View {
        let agents = dragged(item).compactMap(agent(for:))
        let tearing = drag.target == .window
        return HStack(spacing: UIScale.pt(6)) {
            if agents.count > 1 {
                HerdrKindMarks(agents: agents, dark: dark, size: 11)
            } else if let agent = agents.first {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(12))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            Text(ghostTitle(agents, tearing: tearing))
                .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
            if drag.target == nil {
                Image(systemName: "nosign")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(6))
        .background(DashSkin.paper2(dark), in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                drag.target == nil ? DashSkin.lineStrong(dark) : accent, lineWidth: 1)
        }
        .shadow(color: .black.opacity(dark ? 0.4 : 0.16), radius: 10, y: 4)
        .fixedSize()
        .opacity(drag.target == nil ? 0.8 : 1)
        .offset(x: drag.location.x + UIScale.pt(14), y: drag.location.y + UIScale.pt(12))
    }

    private func ghostTitle(_ agents: [HerdrAgent], tearing: Bool) -> String {
        if tearing { return "Open in a New Window" }
        guard let first = agents.first else { return "Agent" }
        let title = hideAgents ? first.kind : first.title
        return agents.count > 1 ? "\(title) +\(agents.count - 1)" : title
    }

    private func dragged(_ item: HerdrDragItem) -> [String] {
        switch store.normalized(item) {
        case let .agent(agent): [agent.id]
        case let .tab(id): store.tab(id)?.agentIDs ?? []
        }
    }

    private func agent(for id: String) -> HerdrAgent? {
        if let session = store.session(id) { return session.agent }
        if case let .agent(agent) = drag.item, agent.id == id { return agent }
        return nil
    }
}
