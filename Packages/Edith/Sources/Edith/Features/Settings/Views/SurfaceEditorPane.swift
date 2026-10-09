import AppKit
import EdithKit
import SwiftUI

struct SurfaceEditorPane: View {
    @State private var store = SurfaceLayoutStore.shared
    @State private var dashboard = DashboardModel.shared
    @State private var activity = AgentActivityMonitor.shared
    @AppStorage(AppStorageKeys.Surfaces.editorTarget, store: SharedDefaults.store) private
        var targetRaw = "home"
    private var target: SurfaceTarget { SurfaceTarget(rawValue: targetRaw) ?? .home }
    @AppStorage(AppStorageKeys.Surfaces.editorWidget, store: SharedDefaults.store) private
        var selectedRaw = ""
    private var selected: String? {
        get { selectedRaw.isEmpty ? nil : selectedRaw }
        nonmutating set { selectedRaw = newValue ?? "" }
    }
    @State private var query = ""
    @State private var libraryCategory = ExtensionMarketplaceCategory.all
    @State private var enabledOnly = false
    @State private var previewCompact = false
    @State private var previewWidth: Double?
    @State private var livePreview = true
    @State private var geometryExpanded = false
    @State private var glancesExpanded = true
    @State private var libraryVisible = true
    @State private var inspectorVisible = true
    @State private var profilesExpanded = false
    @State private var profileName = ""
    @State private var renamingProfile: UUID?
    @State private var renamedProfile = ""
    @State private var layoutError: String?
    @State private var sourceChoices: [SurfaceSourceChoice] = []
    @State private var sourceLoad = ContentLoad()
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var canvasWidth = 600.0
    @State private var libraryDrag: SurfaceLibraryPreview?
    @State private var canvasGlobalFrame = CGRect.zero
    @State private var canvasViewport = CGRect.zero
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    private var layout: SurfaceLayout { store.layout(target) }
    private var selection: SurfaceTile? { layout.tiles.first { $0.id == selected } }

    var body: some View {
        PageWorkspace {
            toolbar
                .padding(.horizontal, PageMetrics.gutter(compact))
                .padding(.vertical, UIScale.pt(12))
            Divider()
        } content: {
            if compact {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        if libraryVisible { ScrollView { library }.frame(height: UIScale.pt(220)) }
                        canvas
                        if inspectorVisible { inspector }
                        if target == .notch { notchTabs }
                    }
                    .padding(PageMetrics.gutter(compact))
                }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    canvasViewport = $0
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    if libraryVisible {
                        ScrollView { library.padding(UIScale.pt(12)) }
                            .frame(width: UIScale.pt(220))
                        Divider()
                    }
                    ScrollView(previewWidth == nil ? .vertical : [.horizontal, .vertical]) {
                        VStack(spacing: UIScale.pt(18)) {
                            canvas
                            if target == .notch { notchTabs }
                        }
                        .frame(width: previewWidth.map { CGFloat(UIScale.pt($0)) })
                        .padding(UIScale.pt(16))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        canvasViewport = $0
                    }
                    if inspectorVisible {
                        Divider()
                        ScrollView { inspector.padding(UIScale.pt(12)) }
                            .frame(width: UIScale.pt(260))
                    }
                }
            }
        }
        .id(target)
        .pageTask(id: livePreview, active: livePreview && target == .home) {
            await dashboard.restoreCachedHomeUsage()
            await dashboard.load()
        }
        .pageTask(
            id: "editor-agent-sources",
            active: selection?.widget == .agents || (target == .notch && glancesExpanded)
        ) {
            await activity.observe()
        }
        .pageTask(id: "\(selectedRaw):\(livePreview):\(targetRaw)") {
            sourceChoices = []
            guard var tile = selection, tile.widget.supportsSourceFilters,
                tile.widget.sourceChoices.isEmpty
            else { return }
            tile.sourceIDs = nil
            if !livePreview || target == .notch {
                sourceChoices = SurfaceSampleData.snapshot(tile).sources
                return
            }
            guard tile.widget.available(in: SharedDefaults.store) else { return }
            let queryTile = tile
            await sourceLoad.perform(
                operation: {
                    try await SurfaceExtensionClient.shared.snapshot(queryTile)
                }, apply: { sourceChoices = $0.sources })
        }
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
                    targetPicker
                    history
                }
            }
            if let layoutError {
                Text(layoutError).font(.edithText(.caption)).foregroundStyle(.red)
            }
            canvasSettings
            savedLayouts
            Text(
                "Drag widgets onto the grid. Move with the title handle and resize with the corner. Use the inspector for precise values. Changes appear immediately."
            )
            .font(.edithText(.callout)).foregroundStyle(.secondary)
        }
    }

    private var savedLayouts: some View {
        DisclosureGroup("Saved layouts", isExpanded: $profilesExpanded) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack {
                    TextField("Layout name", text: $profileName).textFieldStyle(.roundedBorder)
                    Button("Save current") {
                        if store.saveProfile(profileName, target: target) {
                            profileName = ""
                            layoutError = nil
                        } else {
                            layoutError =
                                "Choose a unique layout name. Each surface supports 20 saved layouts, up to 1 MB in total."
                        }
                    }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !store.profiles(target).isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                            ForEach(store.profiles(target)) { profile in
                                HStack {
                                    if renamingProfile == profile.id {
                                        TextField("Rename layout", text: $renamedProfile)
                                            .textFieldStyle(
                                                .roundedBorder)
                                        Button("Save name") {
                                            if store.renameProfile(profile.id, name: renamedProfile)
                                            {
                                                renamingProfile = nil
                                                layoutError = nil
                                            } else {
                                                layoutError =
                                                    "Choose a unique, nonempty layout name."
                                            }
                                        }
                                        Button("Cancel") { renamingProfile = nil }
                                    } else {
                                        Text(profile.name).lineLimit(1)
                                        Spacer()
                                        Button("Apply") {
                                            store.applyProfile(profile.id); selected = nil
                                        }
                                        Menu {
                                            Button("Update from current layout") {
                                                if !store.saveProfile(
                                                    profile.name, target: target,
                                                    replacing: profile.id)
                                                {
                                                    layoutError =
                                                        "This saved layout exceeds the 1 MB storage limit."
                                                }
                                            }
                                            Button("Rename") {
                                                renamingProfile = profile.id;
                                                renamedProfile = profile.name
                                            }
                                            Button("Delete") { store.removeProfile(profile.id) }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                        }
                                        .help("Manage " + profile.name)
                                    }
                                }
                            }
                        }
                    }.frame(height: UIScale.pt(min(180, Double(store.profiles(target).count) * 36)))
                }
                if store.canRestoreProfile(target) {
                    Button("Restore deleted layout") {
                        if !store.restoreProfile(target) {
                            layoutError =
                                "Rename the conflicting layout or remove a saved layout before restoring."
                        }
                    }
                }
                Text("Home and Notch have separate saved layouts. Applying a layout can be undone.")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
            }.padding(.top, UIScale.pt(8))
        }.font(.edithText(.callout))
    }

    private var canvasSettings: some View {
        DisclosureGroup("Canvas geometry", isExpanded: $geometryExpanded) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                Stepper(
                    "Grid: \(layout.columns) columns",
                    value: Binding(
                        get: { layout.columns },
                        set: { value in store.update(target) { $0.resampleGrid(columns: value) } }),
                    in: 4...SurfaceLayout.maximumColumns)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: UIScale.pt(100)))]) {
                    numberField("Gap (pt)", value: canvasSetting(\.gap))
                    numberField("Padding (pt)", value: canvasSetting(\.padding))
                    numberField("Corners (pt)", value: canvasSetting(\.cornerRadius))
                    numberField(
                        "Snap (pt)",
                        value: Binding(
                            get: { layout.rowHeight },
                            set: { value in store.update(target) { $0.resampleGrid(snap: value) } })
                    )
                }
                HStack {
                    Button("Balanced grid") {
                        store.update(target) { $0.resampleGrid(columns: 24, snap: 8) }
                    }
                    Button("Fine grid") {
                        store.update(target) { $0.resampleGrid(columns: 192, snap: 1) }
                    }
                }.buttonStyle(.edith(.secondary))
                Text(
                    "Changing the grid preserves widget proportions and vertical positions. Fine mode snaps vertically to one point."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
                if target == .notch {
                    Toggle("Horizontal widget shelf", isOn: canvasSetting(\.notchHorizontal))
                    numberField("Shelf card width (pt)", value: canvasSetting(\.notchCardWidth))
                    numberField("Expanded width (pt)", value: canvasSetting(\.notchWidth))
                    numberField("Shelf height (pt)", value: canvasSetting(\.notchShelfHeight))
                }
                Button("Pack widgets automatically") {
                    store.update(target) { $0.arrangeAutomatically() }
                }
                .buttonStyle(.edith(.secondary))
            }
            .padding(.top, UIScale.pt(8))
        }
        .font(.edithText(.callout))
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title).font(.edithText(.caption)).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func canvasSetting<Value>(_ key: WritableKeyPath<SurfaceLayout, Value>) -> Binding<
        Value
    > {
        Binding(
            get: { layout[keyPath: key] },
            set: { value in
                store.update(target) { $0[keyPath: key] = value }
            })
    }

    private var targetPicker: some View {
        EdithSegmentedPicker(
            "Surface",
            selection: Binding(
                get: { target },
                set: {
                    selected = nil
                    targetRaw = $0.rawValue
                }),
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
            Menu {
                Toggle("Widget library", isOn: $libraryVisible)
                Toggle("Widget inspector", isOn: $inspectorVisible)
                Divider()
                Button("Copy layout") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(layout.encoded, forType: .string)
                }
                Button("Paste layout") {
                    guard let text = NSPasteboard.general.string(forType: .string),
                        let data = text.data(using: .utf8), data.count <= 1_048_576,
                        let imported = try? JSONDecoder().decode(SurfaceLayout.self, from: data),
                        imported.tiles.count <= SurfaceLayout.maximumTiles
                    else {
                        layoutError = "The clipboard does not contain a valid surface layout."
                        return
                    }
                    store.update(target) { $0 = imported }
                    selected = nil
                    layoutError = nil
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Workspace panels and layout sharing")
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

    private var libraryWidgets: [SurfaceWidget] {
        SurfaceWidget.allCases.filter { widget in
            let matchesQuery =
                query.isEmpty
                || (widget.title + " " + widget.summary)
                    .localizedCaseInsensitiveContains(query)
            let matchesSuite = libraryCategory.suite == nil || widget.suite == libraryCategory.suite
            return matchesQuery && matchesSuite
                && (!enabledOnly || widget.available(in: SharedDefaults.store))
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("Widget library").font(.edithText(.headline))
            SearchField(placeholder: "Find widgets", text: $query)
            Picker("Category", selection: $libraryCategory) {
                ForEach(ExtensionMarketplaceCategory.allCases, id: \.self) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            Toggle("Enabled only", isOn: $enabledOnly)
            Text("\(libraryWidgets.count) widgets").font(.edithText(.caption)).foregroundStyle(
                .secondary)
            if libraryWidgets.isEmpty {
                Text("No widgets match these filters.").font(.edithText(.caption)).foregroundStyle(
                    .secondary)
            }
            ForEach(libraryWidgets) { widget in
                HStack(alignment: .top, spacing: UIScale.pt(10)) {
                    Image(systemName: widget.icon).foregroundStyle(Color.accentColor).frame(
                        width: UIScale.pt(20), height: UIScale.pt(28)
                    )
                    .contentShape(Rectangle())
                    .help("Drag " + widget.title + " onto the canvas")
                    .accessibilityLabel("Drag " + widget.title)
                    .highPriorityGesture(libraryGesture(widget))
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(widget.title).font(.edithText(.callout))
                        Text(widget.summary).font(.edithText(.caption)).foregroundStyle(.secondary)
                        if !widget.available(in: SharedDefaults.store) {
                            Text("Enable in Extensions to use").font(.edithText(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onDrag { SurfaceDrag.provider(widget) }
                    Spacer(minLength: 0)
                    Button {
                        store.update(target) { selected = $0.add(widget) }
                        inspectorVisible = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.edith(.borderless))
                    .help("Add \(widget.title)")
                    .accessibilityLabel("Add \(widget.title)")
                }
                .padding(UIScale.pt(10))
                .background(
                    Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(10))
                )
                .contentShape(Rectangle())
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
                    previewTitle
                    Spacer()
                    previewToggle
                }
                VStack(alignment: .leading) {
                    previewTitle
                    previewToggle
                }
            }
            if target == .notch {
                collapsedPreview
            }
            previewCanvas
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    canvasGlobalFrame = $0
                }
                .overlay {
                    if target == .notch, layout.notchHorizontal, localLibraryPreview != nil {
                        RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                            Color.accentColor, lineWidth: 2
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Text("Add " + (libraryDrag?.widget.title ?? "widget"))
                                .font(.edithText(.caption)).padding(UIScale.pt(8))
                                .background(.regularMaterial, in: Capsule())
                        }.allowsHitTesting(false)
                    }
                }
                .onGeometryChange(for: Double.self) {
                    $0.size.width / UIScale.current
                } action: {
                    canvasWidth = $0
                }
                .padding(UIScale.pt(12))
                .background(
                    target == .notch ? Color.black : Color.secondary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(target == .notch ? 22 : 14))
                )
                .environment(\.colorScheme, target == .notch ? .dark : scheme)
                .frame(maxWidth: target == .notch ? UIScale.pt(layout.notchWidth) : .infinity)
            Text(
                livePreview && target == .home
                    ? "Live content. Controls are paused while editing."
                    : "Sample content. Edit the Notch itself to preview live widgets."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            if target == .notch { glanceSettings }
        }
    }

    @ViewBuilder private var previewCanvas: some View {
        if target == .notch && layout.notchHorizontal {
            SurfaceShelf(
                layout: layout, editing: true, selected: selected,
                select: { selected = $0 }, inspect: { selected = $0 },
                reorder: { id, anchor in store.update(target) { $0.move(id, before: anchor) } },
                configure: { tile in edit(tile.id) { $0 = tile } },
                add: { widget in store.update(target) { selected = $0.add(widget) } }
            ) { tile in SurfaceWidgetPreview(tile: tile, notch: true) }
        } else {
            SurfaceCanvas(
                layout: layout, singleColumn: compact || previewCompact,
                editing: true, selected: selected, libraryPreview: localLibraryPreview,
                select: { selected = $0 },
                place: { widget, anchor in
                    store.update(target) { layout in
                        let id = layout.add(widget)
                        if let anchor { layout.move(id, before: anchor) }
                        selected = id
                    }
                },
                measured: { id, frame in
                    if tileFrames[id] != frame { tileFrames[id] = frame }
                },
                reorder: { id, anchor in store.update(target) { $0.move(id, before: anchor) } },
                configure: { tile in
                    store.update(target) { layout in
                        if compact || previewCompact,
                            let index = layout.tiles.firstIndex(where: { $0.id == tile.id })
                        {
                            layout.tiles[index] = tile
                        } else {
                            layout.position(tile)
                        }
                    }
                },
                placeAt: { widget, column, row in
                    store.update(target) { layout in
                        selected = layout.add(widget, column: column, row: row)
                    }
                }
            ) { tile in
                if livePreview, target == .home {
                    HomeSurfaceWidget(tile: tile)
                        .environment(\.compactLayout, compact || previewCompact)
                } else {
                    SurfaceWidgetPreview(tile: tile, notch: target == .notch)
                }
            }
        }
    }

    private var localLibraryPreview: SurfaceLibraryPreview? {
        guard let drag = libraryDrag,
            canvasGlobalFrame.intersection(canvasViewport).contains(drag.point)
        else { return nil }
        return .init(
            widget: drag.widget,
            point: CGPoint(
                x: drag.point.x - canvasGlobalFrame.minX, y: drag.point.y - canvasGlobalFrame.minY))
    }

    private func libraryGesture(_ widget: SurfaceWidget) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in libraryDrag = .init(widget: widget, point: value.location) }
            .onEnded { value in
                libraryDrag = .init(widget: widget, point: value.location)
                defer { libraryDrag = nil }
                guard let preview = localLibraryPreview else { return }
                store.update(target) { layout in
                    if target == .notch && layout.notchHorizontal {
                        selected = layout.add(widget)
                    } else if compact || previewCompact {
                        let anchor = layout.visible.first {
                            (tileFrames[$0.id]?.midY ?? .infinity) * UIScale.current
                                > preview.point.y
                        }?.id
                        let id = layout.add(widget)
                        if let anchor { layout.move(id, before: anchor) }
                        selected = id
                    } else {
                        let pitch = max(0.01, (canvasWidth + layout.gap) / Double(layout.columns))
                        let column = max(
                            0,
                            min(layout.columns - 1, Int(preview.point.x / UIScale.current / pitch)))
                        let row = max(
                            0,
                            min(
                                SurfaceLayout.maximumRow,
                                Int((preview.point.y / UIScale.pt(layout.rowHeight)).rounded())))
                        selected = layout.add(widget, column: column, row: row)
                    }
                }
            }
    }

    private var collapsedPreview: some View {
        let now = Date()
        let sessions = (0..<4).map { index in
            AgentActivitySession(
                event: AgentActivityEvent(
                    provider: .codex,
                    sessionID: "preview-\(index)", eventName: "UserPromptSubmit",
                    phase: index == 3 ? .waiting : .working, project: "/tmp/demo", receivedAt: now))
        }
        let context = SurfaceGlanceContext(
            agents: AgentActivityPresentation(
                activity: AgentActivitySnapshot(sessions: sessions, refreshedAt: now), now: now),
            observing: true, monitoringStalls: true, hasMusic: true, playingMusic: true,
            files: 3, now: now, focus: AttentionFocusSession(name: "Focus", plannedDuration: 1500),
            quotaRemaining: 62, nextMeeting: now.addingTimeInterval(1200))
        let left = context.resolve(layout.notchLeadingGlance, leading: true)
        let right = context.resolve(layout.notchTrailingGlance, leading: false)
        let width = left == nil && right == nil ? 0 : layout.notchWingWidth
        return HStack(spacing: 0) {
            glancePreview(left, width: width)
            Color.black.frame(width: UIScale.pt(150), height: UIScale.pt(28))
            glancePreview(right, width: width)
        }
        .background(
            .black, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
        )
        .frame(maxWidth: .infinity)
    }

    private func glancePreview(_ glance: SurfaceGlance?, width: Double) -> some View {
        HStack(spacing: UIScale.pt(5)) {
            if let glance {
                SurfaceGlanceLabel(glance)
            }
        }
        .font(.edithText(.caption)).foregroundStyle(.white.opacity(0.85))
        .frame(width: UIScale.pt(width), height: UIScale.pt(28))
    }

    private var glanceSettings: some View {
        DisclosureGroup("Collapsed Notch", isExpanded: $glancesExpanded) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                Text(
                    "Choose what each side shows. The center stays clear for the hardware camera cutout."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
                Picker("Left indicator", selection: canvasSetting(\.notchLeadingGlance)) {
                    ForEach(SurfaceGlanceSource.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                Picker("Right indicator", selection: canvasSetting(\.notchTrailingGlance)) {
                    ForEach(SurfaceGlanceSource.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                numberField("Indicator width (pt)", value: canvasSetting(\.notchWingWidth))
                Toggle("Include subagents in counts", isOn: canvasSetting(\.notchIncludeSubagents))
                Toggle(
                    "All agent providers",
                    isOn: Binding(
                        get: { layout.notchAgentSources == nil },
                        set: { all in store.update(.notch) { $0.notchAgentSources = all ? nil : [] }
                        }))
                if layout.notchAgentSources != nil {
                    ForEach(agentProviderChoices, id: \.id) { provider in
                        Toggle(
                            provider.title,
                            isOn: Binding(
                                get: { layout.notchAgentSources?.contains(provider.id) == true },
                                set: { enabled in
                                    store.update(.notch) {
                                        if enabled {
                                            $0.notchAgentSources?.insert(provider.id)
                                        } else {
                                            $0.notchAgentSources?.remove(provider.id)
                                        }
                                    }
                                }))
                    }
                }
                Toggle(
                    "Prioritize permissions when opening Notch",
                    isOn: canvasSetting(\.notchPrioritizePermissions))
                Toggle(
                    "Open Notch automatically for new permissions",
                    isOn: canvasSetting(\.notchExpandPermissions))
                Text(
                    "Provider filters apply to session counts and lists. The Agents view keeps every pending permission reachable."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }.padding(.top, UIScale.pt(8))
        }.padding(UIScale.pt(16))
            .background(
                Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
    }

    private var previewTitle: some View {
        Label(
            "\(target.title) canvas",
            systemImage: target == .home ? "house" : "rectangle.topthird.inset.filled"
        )
        .font(.edithText(.headline))
    }
    private var previewToggle: some View {
        HStack {
            if !compact, target == .home {
                Menu(previewWidth.map { "\(Int($0)) pt" } ?? "Fit") {
                    Button("Fit workspace") { previewWidth = nil }
                    ForEach([420.0, 900, 1200, 1440, 1920], id: \.self) { width in
                        Button("\(Int(width)) pt") {
                            previewWidth = width
                            previewCompact = width == 420
                        }
                    }
                }.help("Preview the actual canvas width")
            }
            if target == .home { Toggle("Live content", isOn: $livePreview) }
            if target != .notch || !layout.notchHorizontal {
                Toggle("Single column", isOn: $previewCompact)
            }
        }
        .toggleStyle(.switch).font(.edithText(.caption))
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
                    .onDrag { SurfaceTabDrag.provider(raw) }
                    .onDrop(of: [SurfaceTabDrag.type], isTargeted: nil) { providers in
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
            if selection == nil {
                Label("Select a widget", systemImage: "cursorarrow.click")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                Text(
                    "Click a widget or drag its handle. Its position, size, data, and appearance controls appear here."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if let tile = selection {
                Toggle(
                    "Lock layout",
                    isOn: Binding(
                        get: { selection?.locked ?? false },
                        set: { locked in
                            edit(tile.id) {
                                $0.locked = locked
                                if locked && (target != .notch || !layout.notchHorizontal) {
                                    let origin = tileFrames[tile.id] ?? .zero
                                    let pitch = (canvasWidth + layout.gap) / Double(layout.columns)
                                    $0.column = Int((origin.minX / pitch).rounded())
                                    $0.row = Int((origin.minY / layout.rowHeight).rounded())
                                }
                            }
                        }))
                TextField("Display title", text: setting(tile.id, \.title, fallback: ""))
                    .textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    if target == .notch && layout.notchHorizontal {
                        overrideField(
                            "Custom shelf width", id: tile.id, key: \.shelfWidth,
                            inherited: layout.notchCardWidth)
                    } else {
                        Stepper(
                            "Width: \(tile.span) / \(layout.columns) columns",
                            value: setting(tile.id, \.span, fallback: 12), in: 1...layout.columns)
                        numberField(
                            "Grid width at this canvas (pt)",
                            value: Binding(
                                get: {
                                    Double(selection?.span ?? tile.span)
                                        * (canvasWidth + layout.gap) / Double(layout.columns)
                                        - layout.gap
                                },
                                set: { value in
                                    guard value.isFinite else { return }
                                    let pitch = (canvasWidth + layout.gap) / Double(layout.columns)
                                    edit(tile.id) {
                                        $0.span = min(
                                            layout.columns,
                                            max(
                                                1,
                                                Int(
                                                    ((min(10_000, max(1, value)) + layout.gap)
                                                        / max(0.01, pitch)).rounded())))
                                    }
                                }))
                    }
                    Toggle(
                        "Automatic height",
                        isOn: Binding(
                            get: { selection?.height == nil },
                            set: { automatic in edit(tile.id) { $0.height = automatic ? nil : 200 }
                            }))
                    if let height = tile.height {
                        numberField(
                            "Height (pt)",
                            value: Binding(
                                get: { selection?.height ?? height },
                                set: { value in edit(tile.id) { $0.height = value } }))
                    }
                    if target != .notch || !layout.notchHorizontal {
                        Toggle(
                            "Automatic placement",
                            isOn: Binding(
                                get: { selection?.column == nil && selection?.row == nil },
                                set: { automatic in
                                    edit(tile.id) {
                                        $0.column = automatic ? nil : 0
                                        $0.row = automatic ? nil : 0
                                    }
                                }))
                        if tile.column != nil || tile.row != nil {
                            numberField(
                                "Horizontal position (pt)",
                                value: Binding(
                                    get: {
                                        Double(selection?.column ?? 0) * (canvasWidth + layout.gap)
                                            / Double(layout.columns)
                                    },
                                    set: { value in
                                        guard value.isFinite else { return }
                                        let pitch =
                                            (canvasWidth + layout.gap) / Double(layout.columns)
                                        edit(tile.id) {
                                            $0.column = min(
                                                layout.columns - $0.span,
                                                max(
                                                    0,
                                                    Int(
                                                        (min(10_000, max(0, value))
                                                            / max(0.01, pitch)).rounded())))
                                        }
                                    }))
                            numberField(
                                "Vertical position (pt)",
                                value: Binding(
                                    get: { Double(selection?.row ?? 0) * layout.rowHeight },
                                    set: { value in
                                        guard value.isFinite else { return }
                                        edit(tile.id) {
                                            $0.row = min(
                                                SurfaceLayout.maximumRow,
                                                max(
                                                    0,
                                                    Int(
                                                        (min(1_000_000, max(0, value))
                                                            / layout.rowHeight).rounded())))
                                        }
                                    }))
                            Stepper(
                                "Column: \(tile.column ?? 0)",
                                value: Binding(
                                    get: { selection?.column ?? 0 },
                                    set: { value in edit(tile.id) { $0.column = value } }),
                                in: 0...max(0, layout.columns - tile.span))
                            Stepper(
                                "Vertical position: \(Int(Double(tile.row ?? 0) * layout.rowHeight)) pt",
                                value: Binding(
                                    get: { selection?.row ?? 0 },
                                    set: { value in edit(tile.id) { $0.row = value } }),
                                in: 0...SurfaceLayout.maximumRow)
                        }
                        nudgeControls(tile).disabled(tile.locked)
                    }
                }.disabled(tile.locked)
                Divider()
                Text("Content").font(.edithText(.headline))
                Toggle("Show title", isOn: setting(tile.id, \.showTitle, fallback: true))
                Toggle("Show details", isOn: setting(tile.id, \.showDetails, fallback: true))
                Toggle("Show actions", isOn: setting(tile.id, \.showActions, fallback: true))
                overrideField(
                    "Custom padding", id: tile.id, key: \.paddingOverride, inherited: layout.padding
                )
                overrideField(
                    "Custom corners", id: tile.id, key: \.cornerOverride,
                    inherited: layout.cornerRadius)
                Toggle("Dense content", isOn: setting(tile.id, \.dense, fallback: false))
                Toggle("Accent color", isOn: setting(tile.id, \.accent, fallback: true))
                Stepper(
                    "Visible items: \(tile.itemLimit)",
                    value: setting(tile.id, \.itemLimit, fallback: 5), in: 1...20)
                ForEach(tile.widget.fields, id: \.0) { field in
                    Toggle(
                        field.1,
                        isOn: Binding(
                            get: { selection?.shows(field.0) ?? true },
                            set: { visible in
                                edit(tile.id) {
                                    if visible {
                                        $0.hiddenFields.remove(field.0)
                                    } else {
                                        $0.hiddenFields.insert(field.0)
                                    }
                                }
                            }))
                }
                if tile.widget == .agents { agentFilters(tile) }
                if tile.widget.supportsSourceFilters { extensionSources(tile) }
                if !tile.widget.contentChoices.isEmpty { extensionContent(tile) }
                if tile.widget == .focus {
                    Stepper(
                        "Focus duration: \(tile.focusMinutes) minutes",
                        value: setting(tile.id, \.focusMinutes, fallback: 25), in: 1...180)
                }
                if tile.widget == .codeStats {
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

    private func extensionContent(_ tile: SurfaceTile) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text("Include").font(.edithText(.headline))
            Toggle(
                "All content",
                isOn: Binding(
                    get: { selection?.contentKinds == nil },
                    set: { all in edit(tile.id) { $0.contentKinds = all ? nil : [] } }))
            if tile.contentKinds != nil {
                ForEach(tile.widget.contentChoices) { choice in
                    Toggle(
                        choice.title,
                        isOn: Binding(
                            get: { selection?.contentKinds?.contains(choice.id) == true },
                            set: { enabled in
                                edit(tile.id) {
                                    if enabled {
                                        $0.contentKinds?.insert(choice.id)
                                    } else {
                                        $0.contentKinds?.remove(choice.id)
                                    }
                                }
                            }))
                }
            }
        }
    }

    private func extensionSources(_ tile: SurfaceTile) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text("Sources").font(.edithText(.headline))
            Toggle(
                "All sources",
                isOn: Binding(
                    get: { selection?.sourceIDs == nil },
                    set: { all in edit(tile.id) { $0.sourceIDs = all ? nil : [] } }))
            if tile.sourceIDs != nil {
                let choices =
                    tile.widget.sourceChoices.isEmpty ? sourceChoices : tile.widget.sourceChoices
                ForEach(choices) { choice in
                    Toggle(
                        choice.title,
                        isOn: Binding(
                            get: { selection?.sourceIDs?.contains(choice.id) == true },
                            set: { enabled in
                                edit(tile.id) {
                                    if enabled {
                                        $0.sourceIDs?.insert(choice.id)
                                    } else {
                                        $0.sourceIDs?.remove(choice.id)
                                    }
                                }
                            }))
                }
                if choices.isEmpty {
                    Text(sourceLoad.errorMessage ?? "No sources available yet.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                if tile.sourceIDs?.isEmpty == true {
                    Text("Select sources to show data in this widget.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var agentProviderChoices: [SurfaceSourceChoice] {
        activity.presentation.providerChoices(
            including: (selection?.sourceIDs ?? []).union(layout.notchAgentSources ?? []))
    }

    private func agentFilters(_ tile: SurfaceTile) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text("Providers").font(.edithText(.headline))
            Toggle(
                "All providers",
                isOn: Binding(
                    get: { selection?.sourceIDs == nil },
                    set: { all in edit(tile.id) { $0.sourceIDs = all ? nil : [] } }))
            if tile.sourceIDs != nil {
                ForEach(agentProviderChoices, id: \.id) { provider in
                    Toggle(
                        provider.title,
                        isOn: Binding(
                            get: { selection?.sourceIDs?.contains(provider.id) == true },
                            set: { enabled in
                                edit(tile.id) {
                                    if enabled {
                                        $0.sourceIDs?.insert(provider.id)
                                    } else {
                                        $0.sourceIDs?.remove(provider.id)
                                    }
                                }
                            }))
                }
            }
            Text("Session states").font(.edithText(.headline))
            Toggle(
                "All states",
                isOn: Binding(
                    get: { selection?.agentPhases == nil },
                    set: { all in edit(tile.id) { $0.agentPhases = all ? nil : [] } }))
            if tile.agentPhases != nil {
                ForEach(AgentActivityPhase.allCases.filter { $0 != .ended }, id: \.rawValue) {
                    phase in
                    Toggle(
                        phase.title,
                        isOn: Binding(
                            get: { selection?.agentPhases?.contains(phase.rawValue) == true },
                            set: { enabled in
                                edit(tile.id) {
                                    if enabled {
                                        $0.agentPhases?.insert(phase.rawValue)
                                    } else {
                                        $0.agentPhases?.remove(phase.rawValue)
                                    }
                                }
                            }))
                }
            }
            Toggle("Include subagents", isOn: setting(tile.id, \.includeSubagents, fallback: true))
        }
    }

    @ViewBuilder private func widgetActions(_ tile: SurfaceTile) -> some View {
        Button("Duplicate") {
            store.update(target) { selected = $0.duplicate(tile.id) }
        }
        Button("Move earlier") { move(tile, offset: -1) }.disabled(
            tile.locked || layout.tiles.first?.id == tile.id)
        Button("Move later") { move(tile, offset: 1) }.disabled(
            tile.locked || layout.tiles.last?.id == tile.id)
        Button("Hide") {
            edit(tile.id) { $0.hidden = true }
            selected = nil
        }
        Button("Remove", role: .destructive) {
            store.update(target) { $0.tiles.removeAll { $0.id == tile.id } }
            selected = nil
        }
    }

    private func overrideField(
        _ title: String, id: String, key: WritableKeyPath<SurfaceTile, Double?>, inherited: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Toggle(
                title,
                isOn: Binding(
                    get: { selection?[keyPath: key] != nil },
                    set: { custom in edit(id) { $0[keyPath: key] = custom ? inherited : nil } }))
            if selection?[keyPath: key] != nil {
                numberField(
                    "Points",
                    value: Binding(
                        get: { selection?[keyPath: key] ?? inherited },
                        set: { value in edit(id) { $0[keyPath: key] = value } }))
            }
        }
    }

    private func nudgeControls(_ tile: SurfaceTile) -> some View {
        HStack {
            nudgeButton("Move left", icon: "arrow.left", key: .leftArrow, column: -1, row: 0)
            nudgeButton("Move up", icon: "arrow.up", key: .upArrow, column: 0, row: -1)
            nudgeButton("Move down", icon: "arrow.down", key: .downArrow, column: 0, row: 1)
            nudgeButton("Move right", icon: "arrow.right", key: .rightArrow, column: 1, row: 0)
        }.buttonStyle(.edith(.secondary))
    }

    private func nudgeButton(
        _ title: String, icon: String, key: KeyEquivalent, column: Int, row: Int
    ) -> some View {
        Button {
            guard var tile = selection, !tile.locked else { return }
            let origin = tileFrames[tile.id] ?? .zero
            let pitch = (canvasWidth + layout.gap) / Double(layout.columns)
            tile.column = max(
                0,
                min(
                    layout.columns - tile.span,
                    (tile.column ?? Int((origin.minX / pitch).rounded())) + column))
            tile.row = max(0, (tile.row ?? Int((origin.minY / layout.rowHeight).rounded())) + row)
            store.update(target) { $0.position(tile) }
        } label: {
            Image(systemName: icon)
        }
        .help(title + " (Option + arrow)")
        .accessibilityLabel(title)
        .keyboardShortcut(key, modifiers: .option)
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
    @ViewBuilder var body: some View {
        if tile.widget.usesExtensionCard {
            SurfaceExtensionCard(
                tile: tile, active: false, fixture: SurfaceSampleData.snapshot(tile), open: { _ in }
            )
        } else if tile.widget == .agents {
            AgentActivityCard(tile: tile, active: false, activity: SurfaceSampleData.agents())
        } else {
            corePreview
        }
    }
    private var corePreview: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            if tile.showTitle {
                Label(tile.displayTitle, systemImage: tile.widget.icon).font(.edithText(.headline))
            }
            if tile.showDetails, !tile.dense {
                Text(tile.widget.summary).font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            previewContent
        }
        .padding(UIScale.pt(tile.paddingOverride ?? (tile.dense ? 10 : 14))).frame(
            maxWidth: .infinity, alignment: .leading
        )
        .background(
            Color.secondary.opacity(notch ? 0.13 : 0.07),
            in: RoundedRectangle(cornerRadius: UIScale.pt(tile.cornerOverride ?? 14)))
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
                if tile.shows("session") { sampleQuota("Session", 63) }
                if tile.shows("weekly") { sampleQuota("Weekly", 34) }
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
                Text("10:00").monospacedDigit()
                Text("Sample design review").lineLimit(1)
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
        case .ability:
            Label(tile.widget.summary, systemImage: tile.widget.icon)
                .font(.edithText(.caption)).foregroundStyle(.secondary)
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
    private func sampleQuota(_ title: String, _ percent: Double) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack {
                Text(title).font(.edithText(.caption))
                Spacer(minLength: 0)
                Text("\(Int(percent))% used").font(.edithText(.caption)).monospacedDigit()
            }
            ProgressView(value: percent, total: 100).tint(
                tile.accent ? Color.accentColor : .secondary)
            if tile.showDetails, tile.shows("resets") {
                Text("Resets in 2h 14m").font(.edithText(.caption2)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity)
    }
}
