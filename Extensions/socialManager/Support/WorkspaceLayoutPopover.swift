import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
protocol WorkspaceLayoutControls: AnyObject {
    var animatesLayout: Bool { get set }
    var layoutAnimation: Animation? { get }
    func templates(for count: Int) -> [HerdrLayoutTemplate]
    func currentTemplate(of tabID: String) -> HerdrLayoutTemplate?
    func arrange(_ tabID: String, as template: HerdrLayoutTemplate)
    func rotate(_ tabID: String)
    func mirror(_ tabID: String, _ axis: SplitAxis)
    func equalize(_ tabID: String)
    func toggleZoom(_ paneID: String)
    func separate(_ tabID: String)
    @discardableResult func saveArrangement(of tabID: String, named name: String)
        -> HerdrSavedArrangement?
    func deleteArrangement(_ id: UUID)
}

struct WorkspaceLayoutPopover<Additions: View>: View {
    let store: any WorkspaceLayoutControls
    let tab: HerdrTab
    let itemName: String
    @ViewBuilder var additions: () -> Additions
    @Environment(\.colorScheme) private var scheme
    @State private var naming = false
    @State private var layoutName = ""

    private var dark: Bool { scheme == .dark }
    private var count: Int { tab.layout.paneCount }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layout")
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Text(count == 1 ? "1 \(itemName)" : "\(count) \(itemName)s")
                    .font(DashSkin.mono(10, weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            if tab.isSplit {
                arrangements
                adjustments
            }
            additions()
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
                    .help("\(template.title): the focused \(itemName) takes the highlighted spot")
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
                "Saved layouts show up here and while dragging whenever \(count) \(itemName)s share a tab."
            )
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
            Toggle(
                "Animate Changes",
                isOn: Binding(get: { store.animatesLayout }, set: { store.animatesLayout = $0 })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .help("Glide tabs and panes into place instead of switching instantly")
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: @escaping () -> Content
    )
        -> some View
    {
        WorkspaceLayoutSection(title: title, content: content)
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

struct WorkspaceLayoutSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            Text(title).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            content()
        }
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
