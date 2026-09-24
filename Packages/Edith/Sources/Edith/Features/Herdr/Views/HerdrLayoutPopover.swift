import EdithKit
import SwiftUI

struct HerdrLayoutPopover: View {
    @Bindable var store: HerdrStore
    let tab: HerdrTab
    let hideAgents: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var naming = false
    @State private var layoutName = ""

    private var dark: Bool { scheme == .dark }
    private var count: Int { tab.agentIDs.count }
    private var otherTabs: [HerdrTab] { store.tabs.filter { $0.id != tab.id } }
    private var candidates: [HerdrAgent] {
        store.listedAgents.filter { !tab.layout.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layout")
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Text(count == 1 ? "1 agent" : "\(count) agents")
                    .font(DashSkin.mono(10, weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            if tab.isSplit {
                arrangements
                adjustments
            }
            additions
            Divider()
            motion
        }
        .padding(UIScale.pt(14))
        .frame(width: UIScale.pt(348))
    }

    private var arrangements: some View {
        let current = store.currentTemplate(of: tab.id)
        return section("Arrange") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(UIScale.pt(74)), spacing: UIScale.pt(6)), count: 4),
                alignment: .leading, spacing: UIScale.pt(8)
            ) {
                ForEach(store.templates(for: count)) { template in
                    Button {
                        perform { store.arrange(tab.id, as: template) }
                    } label: {
                        VStack(spacing: UIScale.pt(4)) {
                            HerdrArrangementThumbnail(
                                template: template, count: count,
                                selected: template == current, dark: dark)
                            HStack(spacing: UIScale.pt(3)) {
                                if template.isSaved {
                                    Image(systemName: "bookmark.fill")
                                        .font(.system(size: UIScale.pt(8)))
                                        .foregroundStyle(DashSkin.accent(dark))
                                }
                                Text(template.title)
                            }
                            .font(.system(size: UIScale.pt(9.5), weight: .medium))
                            .foregroundStyle(
                                template == current ? DashSkin.ink(dark) : DashSkin.inkSoft(dark)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.edith(.borderless))
                    .accessibilityLabel(template.title)
                    .accessibilityAddTraits(template == current ? .isSelected : [])
                    .help("\(template.title): the focused agent takes the highlighted spot")
                    .contextMenu {
                        if case let .saved(saved) = template {
                            Button("Delete Saved Layout", role: .destructive) {
                                perform { store.deleteArrangement(saved.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var adjustments: some View {
        section("Adjust") {
            HStack(spacing: UIScale.pt(6)) {
                action("rotate.right", "Rotate") { store.rotate(tab.id) }
                action("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip") {
                    store.mirror(tab.id, .horizontal)
                }
                action("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Up") {
                    store.mirror(tab.id, .vertical)
                }
                action("equal.square", "Even Out") { store.equalize(tab.id) }
                action(
                    tab.zoomed == nil
                        ? "arrow.up.left.and.arrow.down.right"
                        : "arrow.down.right.and.arrow.up.left",
                    tab.zoomed == nil ? "Zoom" : "Restore"
                ) { store.toggleZoom(tab.focused) }
                action("rectangle.split.3x1", "Separate") { store.separate(tab.id) }
                action("bookmark", "Save") {
                    layoutName = ""
                    naming = true
                }
            }
        }
        .alert("Save This Layout", isPresented: $naming) {
            TextField("Name", text: $layoutName)
            Button("Save") {
                perform { store.saveArrangement(of: tab.id, named: layoutName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Saved layouts show up here and while dragging whenever \(count) agents share a tab."
            )
        }
    }

    private var additions: some View {
        section(tab.isSplit ? "Add to This Tab" : "Open Side by Side") {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                ForEach(otherTabs) { other in
                    Button {
                        perform { store.merge(other.id, into: tab.id) }
                    } label: {
                        HerdrTabSummary(
                            store: store, tab: other, hideAgents: hideAgents, dark: dark)
                    }
                    .buttonStyle(.edith(.borderless))
                    .help("Bring this tab in beside the current agents")
                }
                HStack(spacing: UIScale.pt(8)) {
                    if !otherTabs.isEmpty {
                        Button("Gather All Tabs") {
                            perform { store.gatherAll(into: tab.id) }
                        }
                        .buttonStyle(.edith(.secondary))
                        .help("Show every open tab together in this one")
                    }
                    if !candidates.isEmpty {
                        Menu("Add Agent") {
                            ForEach(candidates) { agent in
                                Button(hideAgents ? agent.kind : agent.title) {
                                    perform { store.open(agent, beside: .right) }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Open another agent beside the focused one")
                    }
                }
                if otherTabs.isEmpty, candidates.isEmpty {
                    Text("Open more agents to place them side by side.")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
    }

    private var motion: some View {
        HStack(spacing: UIScale.pt(8)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Animate Changes")
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(
                    store.animatesLayout
                        ? "Tabs and panes glide into place" : "Tabs and panes switch instantly"
                )
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer(minLength: 0)
            Toggle("Animate Changes", isOn: $store.animatesLayout)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .help("Glide tabs and panes into place instead of switching instantly")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            Text(title)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            content()
        }
    }

    private func action(_ systemImage: String, _ title: String, run: @escaping () -> Void)
        -> some View
    {
        Button {
            perform(run)
        } label: {
            VStack(spacing: UIScale.pt(3)) {
                Image(systemName: systemImage)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .frame(height: UIScale.pt(16))
                Text(title)
                    .font(.system(size: UIScale.pt(9), weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(6))
            .widgetBar(cornerRadius: 7, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(title)
        .help(title)
    }

    private func perform(_ change: () -> Void) {
        withAnimation(store.layoutAnimation, change)
    }
}

struct HerdrArrangementThumbnail: View {
    let template: HerdrLayoutTemplate
    let count: Int
    let selected: Bool
    let dark: Bool
    var highlightedSlot: Int? = 0

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let frames = template.slotFrames(count: count, in: rect, gap: 2)
            for (index, frame) in frames.enumerated() {
                let tint =
                    index == highlightedSlot
                    ? DashSkin.accent(dark).opacity(selected ? 0.85 : 0.55)
                    : DashSkin.ink(dark).opacity(selected ? 0.28 : 0.16)
                context.fill(Path(roundedRect: frame, cornerRadius: 2), with: .color(tint))
            }
        }
        .frame(width: UIScale.pt(70), height: UIScale.pt(46))
        .widgetBar(
            cornerRadius: 7,
            fill: DashSkin.paper2(dark),
            stroke: selected ? DashSkin.accent(dark).opacity(0.7) : DashSkin.line(dark),
            strokeWidth: selected ? 1.4 : 1)
    }
}

struct HerdrTabSummary: View {
    var store: HerdrStore
    let tab: HerdrTab
    let hideAgents: Bool
    let dark: Bool

    private var agents: [HerdrAgent] {
        tab.agentIDs.compactMap { store.session($0)?.agent }
    }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            HerdrKindMarks(agents: agents, dark: dark)
            Text(agents.map(\.title).joined(separator: " · "))
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
                .truncationMode(.tail)
                .presenterTextBlur(hideAgents, fontSize: 11.5)
            Spacer(minLength: 0)
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(6))
        .widgetBar(cornerRadius: 7, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
        .contentShape(Rectangle())
    }
}

struct HerdrKindMarks: View {
    let agents: [HerdrAgent]
    let dark: Bool
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: UIScale.pt(-3)) {
            ForEach(Array(agents.prefix(3).enumerated()), id: \.offset) { _, agent in
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(size))
                    .foregroundStyle(agent.isTerminal ? DashSkin.gold : DashSkin.inkSoft(dark))
                    .padding(UIScale.pt(1.5))
                    .background(DashSkin.paper2(dark), in: Circle())
            }
        }
    }
}
