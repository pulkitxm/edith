import EdithKit
import SwiftUI

struct SurfaceEditorPane: View {
    @State private var store = SurfaceLayoutStore.shared
    @AppStorage(AppStorageKeys.Surfaces.editorTarget, store: SharedDefaults.store) private
        var targetRaw = "home"
    private var target: SurfaceTarget { SurfaceTarget(rawValue: targetRaw) ?? .home }
    @State private var selected: String?
    @State private var query = ""
    @State private var previewCompact = false
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    private var layout: SurfaceLayout { store.layout(target) }
    private var selection: SurfaceTile? { layout.tiles.first { $0.id == selected } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                toolbar
                if compact {
                    ScrollView { library }.frame(height: UIScale.pt(240))
                    if selection != nil { inspector }
                    canvas
                    if target == .notch { notchTabs }
                } else {
                    HStack(alignment: .top, spacing: UIScale.pt(18)) {
                        ScrollView { library }.frame(
                            width: UIScale.pt(210), height: UIScale.pt(650))
                        VStack(spacing: UIScale.pt(18)) {
                            canvas
                            if target == .notch { notchTabs }
                        }.frame(maxWidth: .infinity)
                        if selection != nil { inspector.frame(width: UIScale.pt(230)) }
                    }
                }
            }.padding(PageMetrics.gutter(compact))
        }
        .onAppear {
            selected = SharedDefaults.store.string(forKey: AppStorageKeys.Surfaces.editorWidget)
        }
        .onChange(of: target) { _, _ in selected = nil }
        .onReceive(DistributedNotificationCenter.default().publisher(for: IPC.Name.settingsChanged))
        { _ in store.reload() }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    targetPicker
                    Spacer()
                    history
                }
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    targetPicker; history
                }
            }
            Text(
                "Drag widgets from the library. Drop on a widget to insert before it. Drag the corner to resize. Changes appear immediately."
            )
            .font(.edithText(.callout)).foregroundStyle(.secondary)
        }
    }

    private var targetPicker: some View {
        EdithSegmentedPicker(
            "Surface", selection: Binding(get: { target }, set: { targetRaw = $0.rawValue }),
            options: SurfaceTarget.allCases, label: { $0.title }
        )
        .frame(width: UIScale.pt(200))
    }

    private var history: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                store.undo(target)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo(target))
            .keyboardShortcut("z", modifiers: .command)
            Button {
                store.redo(target)
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!store.canRedo(target))
            .keyboardShortcut("z", modifiers: [.command, .shift])
            Menu("Presets") {
                Button("Default layout") { store.update(target) { $0 = .standard(target) } }
                Button("Developer") {
                    preset([.agents, .limits, .codeStats, .github, .focus, .actions])
                }
                Button("Deep work") { preset([.focus, .calendar, .music, .clocks, .desk]) }
                Button("Studio") { preset([.music, .media, .desk, .actions]) }
                Divider()
                Button("Empty canvas") { store.update(target) { $0.tiles = [] } }
            }
        }.buttonStyle(.edith(.secondary))
    }

    private func preset(_ widgets: [SurfaceWidget]) {
        store.update(target) { $0.tiles = widgets.map { SurfaceTile($0) } }
        selected = nil
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("Widget library").font(.edithText(.headline))
            SearchField(placeholder: "Find widgets", text: $query)
            ForEach(
                SurfaceWidget.allCases.filter {
                    query.isEmpty || ($0.title + $0.summary).localizedCaseInsensitiveContains(query)
                }
            ) { widget in
                HStack(alignment: .top, spacing: UIScale.pt(10)) {
                    Image(systemName: widget.icon).foregroundStyle(Color.accentColor).frame(
                        width: UIScale.pt(20))
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(widget.title).font(.edithText(.callout))
                        Text(widget.summary).font(.edithText(.caption)).foregroundStyle(.secondary)
                        if !widget.available(in: SharedDefaults.store) {
                            Text("Enable in Extensions to use").font(.edithText(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.update(target) { $0.place(widget) }
                        selected = widget.id
                    } label: {
                        Image(
                            systemName: layout.tiles.contains { $0.widget == widget }
                                ? "checkmark" : "plus")
                    }
                    .buttonStyle(.edith(.borderless))
                    .disabled(layout.tiles.contains { $0.widget == widget })
                    .help("Add \(widget.title)")
                    .accessibilityLabel("Add \(widget.title)")
                }
                .padding(UIScale.pt(10))
                .background(
                    Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(10))
                )
                .contentShape(Rectangle())
                .onDrag { SurfaceDrag.provider(widget) }
            }
            if !layout.tiles.filter(\.hidden).isEmpty {
                Text("Hidden widgets").font(.edithText(.headline)).padding(.top, UIScale.pt(8))
                ForEach(layout.tiles.filter(\.hidden)) { tile in
                    Button("Show \(tile.displayTitle)") { edit(tile.id) { $0.hidden = false } }
                        .buttonStyle(.edith(.secondary))
                }
            }
        }
    }

    private var canvas: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    previewTitle; Spacer(); previewToggle
                }
                VStack(alignment: .leading) {
                    previewTitle; previewToggle
                }
            }
            if target == .notch {
                HStack {
                    Spacer();
                    RoundedRectangle(cornerRadius: UIScale.pt(8)).fill(.black).frame(
                        width: UIScale.pt(150), height: UIScale.pt(28));
                    Spacer()
                }
            }
            SurfaceCanvas(
                layout: layout, singleColumn: compact || previewCompact,
                editing: true, selected: selected, select: { selected = $0 },
                place: { widget, anchor in
                    store.update(target) { $0.place(widget, before: anchor) }; selected = widget.id
                },
                resize: { id, size in edit(id) { $0.size = size } }
            ) { tile in
                SurfaceWidgetPreview(tile: tile, notch: target == .notch)
            }
            .padding(UIScale.pt(12))
            .background(
                target == .notch ? Color.black : Color.secondary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: UIScale.pt(target == .notch ? 22 : 14))
            )
            .environment(\.colorScheme, target == .notch ? .dark : scheme)
            .frame(maxWidth: target == .notch ? UIScale.pt(580) : .infinity)
            Text("Preview uses sample content. Your widgets use live data when available.")
                .font(.edithText(.caption)).foregroundStyle(.secondary)
        }
    }

    private var previewTitle: some View {
        Label(
            "\(target.title) canvas",
            systemImage: target == .home ? "house" : "rectangle.topthird.inset.filled"
        )
        .font(.edithText(.headline))
    }
    private var previewToggle: some View {
        Toggle("Single column", isOn: $previewCompact).toggleStyle(.switch).font(
            .edithText(.caption))
    }

    private var notchTabs: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text("Notch tabs").font(.edithText(.headline))
            Text("Drag to reorder. Hidden tabs keep their integration settings.")
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            ForEach(layout.tabOrder, id: \.self) { raw in
                if let tab = SurfaceNotchTab(rawValue: raw) {
                    HStack {
                        Image(systemName: "line.3.horizontal")
                        Label(tab.title, systemImage: tab.icon)
                        Spacer()
                        Toggle(
                            "Visible",
                            isOn: Binding(
                                get: { !layout.hiddenTabs.contains(raw) },
                                set: { visible in
                                    store.update(.notch) { layout in
                                        layout.hiddenTabs.removeAll { $0 == raw }
                                        if !visible { layout.hiddenTabs.append(raw) }
                                    }
                                })
                        ).labelsHidden().disabled(tab == .home)
                    }
                    .font(.edithText(.callout)).padding(UIScale.pt(8))
                    .background(
                        Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .onDrag { NSItemProvider(object: ("edith-notch-tab:" + raw) as NSString) }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        SurfaceTabDrag.accept(providers) { source in
                            store.update(.notch) { layout in
                                guard source != raw else { return }
                                layout.tabOrder.removeAll { $0 == source }
                                let index =
                                    layout.tabOrder.firstIndex(of: raw) ?? layout.tabOrder.endIndex
                                layout.tabOrder.insert(source, at: index)
                            }
                        }
                    }
                }
            }
        }.padding(UIScale.pt(16))
            .background(
                Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                Text(selection.map { "Configure \($0.widget.title)" } ?? "Widget inspector").font(
                    .edithText(.headline))
                Spacer(minLength: 0)
                Button {
                    selected = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.edith(.borderless)).help("Close inspector").accessibilityLabel(
                    "Close inspector")
            }
            if let tile = selection {
                TextField("Display title", text: setting(tile.id, \.title, fallback: ""))
                    .textFieldStyle(.roundedBorder)
                EdithSegmentedPicker(
                    "Size", selection: setting(tile.id, \.size, fallback: .regular),
                    options: SurfaceWidgetSize.allCases, label: { $0.title })
                if tile.widget == .focus {
                    Stepper(
                        "Focus duration: \(tile.focusMinutes) minutes",
                        value: setting(tile.id, \.focusMinutes, fallback: 25), in: 1...180)
                }
                if tile.widget == .codeStats || tile.widget == .github {
                    EdithSegmentedPicker(
                        "Period", selection: setting(tile.id, \.days, fallback: 30),
                        options: [7, 30, 90], label: { "\($0) days" })
                }
                ViewThatFits(in: .horizontal) {
                    HStack { widgetActions(tile) }
                    VStack(alignment: .leading) { widgetActions(tile) }
                }
            } else {
                Text("Select Configure on a widget to change its title, size, and behavior.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
            }
        }
        .padding(UIScale.pt(16))
        .background(
            Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
    }

    @ViewBuilder private func widgetActions(_ tile: SurfaceTile) -> some View {
        Button("Move earlier") { move(tile, offset: -1) }.disabled(
            layout.tiles.first?.id == tile.id)
        Button("Move later") { move(tile, offset: 1) }.disabled(layout.tiles.last?.id == tile.id)
        Button("Hide") {
            edit(tile.id) { $0.hidden = true }; selected = nil
        }
        Button("Remove", role: .destructive) {
            store.update(target) { $0.tiles.removeAll { $0.id == tile.id } }; selected = nil
        }
    }

    private func move(_ tile: SurfaceTile, offset: Int) {
        store.update(target) { layout in
            guard let index = layout.tiles.firstIndex(where: { $0.id == tile.id }),
                layout.tiles.indices.contains(index + offset)
            else { return }
            layout.tiles.swapAt(index, index + offset)
        }
    }
    private func edit(_ id: String, _ change: (inout SurfaceTile) -> Void) {
        store.update(target) { layout in
            guard let index = layout.tiles.firstIndex(where: { $0.id == id }) else { return }
            change(&layout.tiles[index])
        }
    }
    private func setting<Value>(
        _ id: String, _ path: WritableKeyPath<SurfaceTile, Value>, fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { layout.tiles.first { $0.id == id }?[keyPath: path] ?? fallback },
            set: { value in edit(id) { $0[keyPath: path] = value } })
    }
}

private struct SurfaceWidgetPreview: View {
    let tile: SurfaceTile
    let notch: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Label(tile.displayTitle, systemImage: tile.widget.icon).font(.edithText(.headline))
            if tile.size != .compact {
                Text(tile.widget.summary).font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            previewContent
        }
        .padding(UIScale.pt(14)).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(notch ? 0.13 : 0.07),
            in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }
    @ViewBuilder private var previewContent: some View {
        switch tile.widget {
        case .music:
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: "waveform").font(.edithText(.title2))
                    .frame(width: UIScale.pt(42), height: UIScale.pt(42))
                    .background(
                        Color.accentColor.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                VStack(alignment: .leading) {
                    Text("Evening loop").font(.edithText(.callout))
                    Text("Sample artist").font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "pause.fill")
                Image(systemName: "forward.fill")
            }
        case .limits:
            HStack(spacing: UIScale.pt(24)) {
                sampleRing("5h", 63)
                sampleRing("7d", 34)
            }.frame(maxWidth: .infinity)
        case .codeStats, .github:
            sampleMetrics([("Commits", "128"), ("Lines", "12.4k"), ("Streak", "7d")])
        case .agents:
            sampleMetrics([("Working", "2"), ("Needs you", "1"), ("Total", "3")])
        case .usage, .activity:
            sampleMetrics([("Cost", "$8.40"), ("Sessions", "12")])
        case .focus:
            HStack {
                Text("\(tile.focusMinutes):00").font(.edithText(.title2)).monospacedDigit()
                Spacer()
                Text("Start focus").font(.edithText(.caption)).padding(UIScale.pt(6))
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        case .clocks:
            sampleMetrics([("Local", "09:41"), ("London", "05:11")])
        case .calendar:
            HStack {
                Text("10:00").monospacedDigit(); Text("Sample design review").lineLimit(1)
            }
            .font(.edithText(.callout))
        case .actions, .desk, .media:
            HStack(spacing: UIScale.pt(8)) {
                ForEach(
                    tile.widget == .media
                        ? ["Music", "Studio", "Downloads"]
                        : ["Keep awake", "Presenter", "Pick color"], id: \.self
                ) { title in
                    Text(title).font(.edithText(.caption)).lineLimit(1).padding(UIScale.pt(8))
                        .frame(maxWidth: .infinity).background(
                            Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
                }
            }
        case .databases, .machines:
            Label(
                tile.widget == .databases ? "Open database workspace" : "3 registered machines",
                systemImage: "arrow.up.right"
            )
            .font(.edithText(.callout))
        }
    }

    private func sampleMetrics(_ values: [(String, String)]) -> some View {
        HStack {
            ForEach(values, id: \.0) { value in
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(value.1).font(.edithText(.title3)).monospacedDigit()
                    Text(value.0).font(.edithText(.caption)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func sampleRing(_ title: String, _ percent: Double) -> some View {
        VStack(spacing: UIScale.pt(4)) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: UIScale.pt(4))
                Circle().trim(from: 0, to: percent / 100).stroke(
                    Color.accentColor, style: StrokeStyle(lineWidth: UIScale.pt(4), lineCap: .round)
                ).rotationEffect(.degrees(-90))
                Text("\(Int(percent))%").font(.edithText(.caption)).monospacedDigit()
            }.frame(width: UIScale.pt(48), height: UIScale.pt(48))
            Text(title).font(.edithText(.caption)).foregroundStyle(.secondary)
        }
    }

}
