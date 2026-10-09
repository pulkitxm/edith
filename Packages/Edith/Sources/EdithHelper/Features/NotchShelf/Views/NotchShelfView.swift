import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchShelfContentView: View {
    var controller: NotchShelfController
    var displayID: CGDirectDisplayID = 0
    var collapsedBase: CGSize = NotchGeometry.fallbackSize
    var isBuiltin = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var surfaceLayouts = SurfaceLayoutStore.shared
    @Namespace private var tabPill

    private var isExpanded: Bool { controller.isExpanded(on: displayID) }
    private var isHovering: Bool { controller.isHovering(on: displayID) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                CenteredNotchShape(
                    width: shapeSize.width, height: shapeSize.height,
                    topRadius: topRadius, bottomRadius: bottomRadius
                )
                .fill(.black)
                .shadow(color: .black.opacity(isExpanded ? 0.3 : 0), radius: 14, y: 6)
                layers
                    .mask {
                        CenteredNotchShape(
                            width: shapeSize.width, height: shapeSize.height,
                            topRadius: topRadius, bottomRadius: bottomRadius)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(glide, value: shapeSize)
            .animation(glide, value: isExpanded)
            .animation(glide, value: controller.currentAlert)
            .animation(glide, value: controller.activeTab)
            .animation(glide, value: controller.nowPlaying == nil)
            .animation(glide, value: controller.glanceWingWidth)
            .animation(glide, value: isHovering)
            .onReceive(
                DistributedNotificationCenter.default().publisher(for: IPC.Name.settingsChanged)
            ) { _ in surfaceLayouts.reload() }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    controller.hoverChanged(
                        hoverRect(in: geo.size).contains(point), on: displayID)
                case .ended:
                    controller.hoverChanged(false, on: displayID)
                }
            }
        }
    }

    @ViewBuilder private var layers: some View {
        if isExpanded {
            let size = expandedShape
            expanded
                .frame(width: size.width, height: size.height, alignment: .top)
                .transition(contentTransition)
        } else if isBuiltin, let alert = controller.currentAlert {
            NotchAlertDropView(alert: alert, controller: controller, glide: glide)
                .frame(
                    width: NotchGeometry.alertDropSize.width,
                    height: NotchGeometry.alertDropSize.height
                )
                .id(alert.id)
                .transition(reduceMotion ? .opacity : alertHandoff)
        } else {
            let size = NotchGeometry.collapsedSize(
                base: collapsedBase, wingWidth: controller.glanceWingWidth)
            collapsed
                .frame(width: size.width, height: size.height)
                .transition(collapsedTransition)
        }
    }

    private var expandedShape: CGSize {
        controller.expandedSize(on: displayID)
    }

    private var shapeSize: CGSize {
        if isExpanded { return expandedShape }
        if isBuiltin, controller.currentAlert != nil { return NotchGeometry.alertDropSize }
        let collapsed = NotchGeometry.collapsedSize(
            base: collapsedBase, wingWidth: controller.glanceWingWidth)
        return isHovering && !reduceMotion
            ? CGSize(width: collapsed.width + 16, height: collapsed.height + 6) : collapsed
    }

    private var alertHandoff: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.modifier(
                active: NotchRiseFade(offset: 16, visible: false),
                identity: NotchRiseFade(offset: 0, visible: true)
            ).animation(.spring(response: 0.4, dampingFraction: 0.9).delay(0.05)),
            removal: AnyTransition.modifier(
                active: NotchRiseFade(offset: -12, visible: false),
                identity: NotchRiseFade(offset: 0, visible: true)
            ).animation(.easeIn(duration: 0.14)))
    }

    private var collapsedTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.35)),
            removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    private func hoverRect(in panel: CGSize) -> CGRect {
        let shape = shapeSize
        return CGRect(
            x: (panel.width - shape.width) / 2, y: 0, width: shape.width, height: shape.height
        )
        .insetBy(dx: -NotchGeometry.openMargin, dy: -NotchGeometry.openMargin)
    }

    private var topRadius: CGFloat {
        isExpanded || (isBuiltin && controller.currentAlert != nil)
            ? NotchGeometry.expandedTopRadius : 0
    }

    private var bottomRadius: CGFloat {
        if isBuiltin, controller.currentAlert != nil, !isExpanded {
            return NotchGeometry.alertBottomRadius
        }
        return isExpanded
            ? NotchGeometry.expandedBottomRadius : NotchGeometry.collapsedBottomRadius
    }

    private var glide: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        if controller.activeTab == .browser { return .easeOut(duration: 0.16) }
        return .spring(response: isExpanded ? 0.46 : 0.38, dampingFraction: 0.86)
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        if controller.activeTab == .browser {
            return .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.12)),
                removal: .opacity.animation(.easeOut(duration: 0.06)))
        }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private var collapsed: some View {
        HStack(spacing: 0) {
            glance(controller.leadingGlance, leading: true)
            Spacer(minLength: 0)
            glance(controller.trailingGlance, leading: false)
        }
    }

    @ViewBuilder private func glance(_ value: SurfaceGlance?, leading: Bool) -> some View {
        if let value {
            Button {
                if value.source == .music && !leading {
                    controller.nowPlayingPlayPause()
                } else {
                    controller.openGlance(value, on: displayID)
                }
            } label: {
                HStack(spacing: 5) {
                    if value.source == .music {
                        if leading, let artwork = controller.nowPlayingArtwork {
                            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 4)).presenterCover(.music)
                        } else {
                            PlaybackWave(
                                playing: controller.nowPlaying?.isPlaying == true,
                                color: .white.opacity(0.85), barCount: 4
                            ).frame(width: 20)
                        }
                    } else {
                        SurfaceGlanceLabel(value)
                    }
                }
                .foregroundStyle(
                    value.urgency == 2
                        ? Color.red : value.urgency == 1 ? .orange : .white.opacity(0.85)
                )
                .frame(width: controller.glanceWingWidth, height: collapsedBase.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(value.detail + (value.value.isEmpty ? "" : ": " + value.value))
            .accessibilityLabel(value.detail + ", " + value.value)
        } else {
            Color.clear.frame(width: controller.glanceWingWidth, height: collapsedBase.height)
        }
    }

    @ViewBuilder private var expanded: some View {
        if controller.activeTab == .browser, let browser = controller.browser {
            NotchBrowserPane(store: browser) { compactTabs }
                .padding(.top, collapsedBase.height)
        } else {
            VStack(spacing: 6) {
                header
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, collapsedBase.height)
        }
    }

    private var compactTabs: some View {
        HStack(spacing: 2) {
            ForEach(visibleTabs, id: \.self) { tab in
                let active = controller.activeTab == tab
                Button {
                    controller.selectTab(tab)
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(active ? Color.black : Color.white.opacity(0.6))
                        .frame(width: 26, height: 22)
                        .background(
                            active ? Color.white.opacity(0.9) : Color.clear, in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.edith(.borderless))
                .help(tab.title)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            if let icon = controller.nowPlayingAppIcon {
                Button {
                    controller.openNowPlayingApp()
                } label: {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 24, height: 24)
                }.buttonStyle(.edith(.borderless)).help("Open the current music player")
                    .padding(.trailing, 6)
            }
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(visibleTabs, id: \.self) { tab in
                            iconTab(tab).id(tab)
                        }
                    }
                }.scrollIndicators(.hidden)
                    .onChange(of: controller.activeTab) { _, tab in
                        withAnimation(glide) { reader.scrollTo(tab, anchor: .center) }
                    }
            }
            if controller.activeTab == .home {
                Menu {
                    ForEach(SurfacePreset.allCases) { preset in
                        Button {
                            surfaceLayouts.update(.notch) { $0 = preset.layout(for: .notch) }
                        } label: {
                            Label(preset.title, systemImage: preset.icon)
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.3.group").frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton).fixedSize().help("Notch presets")
                if controller.layoutEditing {
                    Button {
                        surfaceLayouts.undo(.notch)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }.disabled(!surfaceLayouts.canUndo(.notch)).help("Undo layout change")
                    Button {
                        surfaceLayouts.redo(.notch)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }.disabled(!surfaceLayouts.canRedo(.notch)).help("Redo layout change")
                }
                Button {
                    controller.layoutEditing.toggle()
                } label: {
                    Image(systemName: controller.layoutEditing ? "checkmark" : "pencil")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.edith(.borderless))
                .help(controller.layoutEditing ? "Finish editing" : "Edit Notch layout")
            }
            Button {
                controller.collapseNow()
                MainApp.openSurfaceEditor(.notch)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 32, height: 22)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.edith(.borderless))
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9),
            value: controller.activeTab)
    }

    private func iconTab(_ tab: NotchTab) -> some View {
        let active = controller.activeTab == tab
        return Button {
            controller.selectTab(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11.5, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold)).fixedSize()
                if tab == .agents, !controller.agentActivity.activity.approvals.isEmpty {
                    Text("\(controller.agentActivity.activity.approvals.count)")
                        .font(.edithText(.caption2)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(active ? 0.25 : 0.3), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.65))
            .background {
                if active {
                    Capsule()
                        .fill(Color.white.opacity(0.93))
                        .matchedGeometryEffect(id: "activeTab", in: tabPill)
                } else {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.edith(.borderless))
        .help(tab.title)
        .onDrag { SurfaceTabDrag.provider(tab.rawValue) }
        .onDrop(of: [SurfaceTabDrag.type], isTargeted: nil) { providers in
            SurfaceTabDrag.accept(providers) { source in
                surfaceLayouts.update(.notch) { layout in
                    guard source != tab.rawValue else { return }
                    layout.tabOrder.removeAll { $0 == source }
                    layout.tabOrder.insert(
                        source,
                        at: layout.tabOrder.firstIndex(of: tab.rawValue) ?? layout.tabOrder.endIndex
                    )
                }
            }
        }
    }

    private var visibleTabs: [NotchTab] {
        _ = surfaceLayouts.notch
        return controller.visibleTabs
    }

    @ViewBuilder private var tabContent: some View {
        switch controller.activeTab {
        case .home: NotchHomeTab(controller: controller)
        case .agents:
            ScrollView {
                AgentActivityCard(
                    tile: agentTile, monitor: controller.agentActivity, allApprovals: true
                )
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        case .browser: EmptyView()
        case .files: filesCanvas
        case .clipboard: NotchClipboardTab(controller: controller)
        case .audio: NotchAudioTab()
        case .camera: NotchCameraTab()
        }
    }

    private var agentTile: SurfaceTile {
        var tile = SurfaceTile(.agents)
        tile.itemLimit = 20
        tile.sourceIDs = surfaceLayouts.notch.notchAgentSources
        tile.includeSubagents = surfaceLayouts.notch.notchIncludeSubagents
        tile.dense = true
        return tile
    }

    private var filesCanvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if controller.items.isEmpty {
                    Text("Drop files here to park them")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ForEach(Array(controller.items.enumerated()), id: \.element.id) {
                        index, item in
                        ShelfItemView(item: item, controller: controller, canvasSize: geo.size)
                            .position(
                                NotchGeometry.itemPosition(
                                    stored: controller.livePositions[item.id] ?? item.position,
                                    index: index, in: geo.size))
                    }
                }
                if let error = controller.shelfOperationError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button {
                            controller.dismissShelfFailure()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.edith(.borderless))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        Color(red: 0.63, green: 0.18, blue: 0.16),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .padding(.horizontal, 16)
                    .frame(maxWidth: geo.size.width, maxHeight: geo.size.height, alignment: .bottom)
                }
            }
            .coordinateSpace(name: "shelfCanvas")
        }
    }
}

private struct NotchHomeTab: View {
    var controller: NotchShelfController
    @AppStorage(AppStorageKeys.General.preventSleep, store: SharedDefaults.store) private
        var preventSleep = false
    @AppStorage(AppStorageKeys.Presenter.mode, store: SharedDefaults.store) private
        var presenterMode = false
    @AppStorage(AppStorageKeys.Presenter.enabled, store: SharedDefaults.store) private
        var presenterEnabled =
        true
    @AppStorage(AppStorageKeys.General.keepAwakeEnabled, store: SharedDefaults.store) private
        var keepAwakeEnabled = false
    @AppStorage(AppStorageKeys.Tabs.systemEnabled, store: SharedDefaults.store) private
        var systemEnabled = true
    @AppStorage(AppStorageKeys.Notch.shelfShowMusic, store: SharedDefaults.store) private
        var showMusic = true
    @AppStorage("lidAwakeActive", store: SharedDefaults.store) private var lidAwakeActive = false
    @State private var pendingLidAwakeSession: LidAwakeSession?

    private var confirmingLidAwake: Binding<Bool> {
        Binding(
            get: { pendingLidAwakeSession != nil },
            set: { showing in
                if !showing { pendingLidAwakeSession = nil }
            })
    }

    @State private var layoutStore = SurfaceLayoutStore.shared
    @State private var selectedTile: String?

    var body: some View {
        Group {
            if layoutStore.notch.notchHorizontal {
                SurfaceShelf(
                    layout: layoutStore.notch, editing: controller.layoutEditing,
                    selected: selectedTile, select: { selectedTile = $0 },
                    inspect: inspect,
                    reorder: { id, anchor in
                        layoutStore.update(.notch) { $0.move(id, before: anchor) }
                    },
                    configure: configure,
                    add: { widget in layoutStore.update(.notch) { selectedTile = $0.add(widget) } },
                    measuredHeight: controller.measureHomeContent
                ) { tile in tileContent(tile) }
            } else {
                ScrollView {
                    SurfaceCanvas(
                        layout: layoutStore.notch, singleColumn: false,
                        editing: controller.layoutEditing, selected: selectedTile,
                        select: { selectedTile = $0 },
                        place: { widget, _ in
                            layoutStore.update(.notch) { selectedTile = $0.add(widget) }
                        },
                        inspect: inspect,
                        reorder: { id, anchor in
                            layoutStore.update(.notch) { $0.move(id, before: anchor) }
                        },
                        configure: { tile in layoutStore.update(.notch) { $0.position(tile) } },
                        placeAt: { widget, column, row in
                            layoutStore.update(.notch) {
                                selectedTile = $0.add(widget, column: column, row: row)
                            }
                        }
                    ) { tile in tileContent(tile) }
                }
            }
            if layoutStore.notch.visible.isEmpty, !controller.layoutEditing {
                Button("Add widgets") {
                    controller.collapseNow()
                    MainApp.openSurfaceEditor(.notch)
                }
                .padding(20)
            }
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16).padding(.bottom, 14)
        .onReceive(DistributedNotificationCenter.default().publisher(for: IPC.Name.settingsChanged))
        { _ in layoutStore.reload() }
    }

    private func inspect(_ id: String) {
        controller.collapseNow()
        MainApp.openSurfaceEditor(.notch, tileID: id)
    }

    private func configure(_ tile: SurfaceTile) {
        layoutStore.update(.notch) { layout in
            guard let index = layout.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
            layout.tiles[index] = tile
        }
    }

    private func tileContent(_ tile: SurfaceTile) -> some View {

        widget(tile)
            .contextMenu {
                Button("Move to first") {
                    layoutStore.update(.notch) { $0.move(tile.id, before: $0.visible.first?.id) }
                }.disabled(tile.locked)
                Button(tile.locked ? "Unlock layout" : "Lock layout") {
                    layoutStore.update(.notch) { layout in
                        guard let index = layout.tiles.firstIndex(where: { $0.id == tile.id })
                        else { return }
                        layout.tiles[index].locked.toggle()
                    }
                }
                Button("Duplicate") { layoutStore.update(.notch) { $0.duplicate(tile.id) } }
                Button("Hide") {
                    layoutStore.update(.notch) { layout in
                        guard
                            let index = layout.tiles.firstIndex(where: { $0.id == tile.id })
                        else { return }
                        layout.tiles[index].hidden = true
                    }
                }
                Button("Open widget editor") {
                    controller.collapseNow()
                    MainApp.openSurfaceEditor(.notch, tileID: tile.id)
                }
            }
    }

    @ViewBuilder private func widget(_ tile: SurfaceTile) -> some View {
        switch tile.widget {
        case .music:
            if let track = controller.nowPlaying {
                NotchNowPlayingCard(controller: controller, track: track, tile: tile).frame(
                    minHeight: tile.dense ? 62 : 92)
            } else {
                emptyMusicCard(tile).frame(height: tile.dense ? 62 : 92)
            }
        case .actions: quickActions(tile)
        case .calendar:
            VStack(alignment: .leading, spacing: tile.dense ? 6 : 10) {
                if tile.showTitle {
                    Label(tile.displayTitle, systemImage: "calendar")
                        .font(.edithText(.caption).weight(.semibold))
                }
                let events = Array(
                    (controller.calendarStore?.events ?? []).filter { $0.end > Date() }.prefix(
                        tile.itemLimit))
                if events.isEmpty {
                    Text("No upcoming meetings").font(.edithText(.caption)).foregroundStyle(
                        .secondary)
                }
                ForEach(events, id: \.id) { event in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).font(.edithText(.caption)).lineLimit(
                                tile.dense ? 1 : 2
                            ).presenterCover(.usage)
                            if tile.showDetails, tile.shows("time") {
                                Text(
                                    event.isAllDay
                                        ? "All day"
                                        : event.start.formatted(.dateTime.hour().minute()) + " to "
                                            + event.end.formatted(.dateTime.hour().minute())
                                )
                                .font(.edithText(.caption2)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if tile.showActions, tile.shows("join"),
                            let url = MeetingLink.url(for: event)
                        {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "video.fill")
                            }.help("Join meeting")
                        }
                    }
                }
                if tile.showActions {
                    Button("Open Calendar") {
                        controller.collapseNow()
                        MainApp.open(section: "calendar")
                    }.font(.edithText(.caption))
                }
            }.padding(SurfacePresentation(tile: tile, layout: layoutStore.notch).padding).frame(
                maxWidth: .infinity, alignment: .leading
            )
            .background(
                .white.opacity(0.055),
                in: RoundedRectangle(
                    cornerRadius: SurfacePresentation(tile: tile, layout: layoutStore.notch)
                        .cornerRadius))
        case .clocks:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    if tile.showTitle {
                        Label(tile.displayTitle, systemImage: "clock").font(
                            .edithText(.caption).weight(.semibold))
                    }
                    Text(context.date.formatted(.dateTime.hour().minute().second())).font(
                        .edithText(.title2).weight(.medium)
                    ).monospacedDigit()
                    if tile.showDetails, !tile.dense {
                        Text(TimeZone.current.identifier).font(.edithText(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }.padding(SurfacePresentation(tile: tile, layout: layoutStore.notch).padding).frame(
                    maxWidth: .infinity, alignment: .leading)
            }.background(
                .white.opacity(0.055),
                in: RoundedRectangle(
                    cornerRadius: SurfacePresentation(tile: tile, layout: layoutStore.notch)
                        .cornerRadius)
            )
        default: integration(tile)
        }
    }

    private func integration(_ tile: SurfaceTile) -> some View {
        SurfaceIntegrationCard(tile: tile) { section in
            controller.collapseNow()
            MainApp.open(section: section)
        }
    }

    private func quickActions(_ tile: SurfaceTile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if tile.showTitle {
                Label(tile.displayTitle, systemImage: "bolt")
                    .font(.edithText(.caption).weight(.semibold))
            }
            SurfaceControlLayout(minimumWidth: 110, cellHeight: tile.dense ? 62 : 82) {
                if systemEnabled {
                    actionTile(tile, "keyboard", "Clean keys", active: false) {
                        controller.cleanKeyboard()
                    }
                }
                if keepAwakeEnabled {
                    actionTile(
                        tile,
                        preventSleep ? "moon.zzz.fill" : "moon.zzz", "Keep awake",
                        active: preventSleep
                    ) {
                        try? ConfigurationExecutor.application.set(
                            .bool(!preventSleep), forKey: AppStorageKeys.General.preventSleep)
                        controller.collapseNow()
                    }
                }
                if controller.canToggleLidAwake {
                    actionTile(tile, "laptopcomputer", "Lid awake", active: lidAwakeActive) {
                        if lidAwakeActive {
                            controller.performLidAwake(.off)
                        } else {
                            pendingLidAwakeSession = .indefinite
                        }
                    }
                    .contextMenu {
                        Button("Indefinitely") {
                            pendingLidAwakeSession = .indefinite
                        }
                        Button("15 minutes") {
                            pendingLidAwakeSession = .fifteenMinutes
                        }
                        Button("30 minutes") {
                            pendingLidAwakeSession = .thirtyMinutes
                        }
                        Button("1 hour") {
                            pendingLidAwakeSession = .oneHour
                        }
                        Button("2 hours") {
                            pendingLidAwakeSession = .twoHours
                        }
                        Button("Until lid reopens") {
                            pendingLidAwakeSession = .untilLidReopens
                        }
                        if lidAwakeActive {
                            Divider()
                            Button("Turn off") {
                                controller.performLidAwake(.off)
                            }
                        }
                    }
                }
                if presenterEnabled {
                    actionTile(tile, "person.wave.2", "Presenter", active: presenterMode) {
                        _ = PresenterRuntimeOperationExecution.perform(
                            presenterMode ? .stop : .start)
                        controller.collapseNow()
                    }
                }
                if controller.canPickColor {
                    actionTile(tile, "eyedropper", "Pick color", active: false) {
                        controller.pickColor()
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(SurfacePresentation(tile: tile, layout: layoutStore.notch).padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            .white.opacity(0.045),
            in: RoundedRectangle(
                cornerRadius: SurfacePresentation(tile: tile, layout: layoutStore.notch)
                    .cornerRadius)
        )
        .alert("Keep running with the lid closed?", isPresented: confirmingLidAwake) {
            Button("Turn On") {
                guard let session = pendingLidAwakeSession else { return }
                pendingLidAwakeSession = nil
                controller.performLidAwake(.on(session))
            }
            Button("Cancel", role: .cancel) {
                pendingLidAwakeSession = nil
            }
        } message: {
            Text(
                pendingLidAwakeSession.flatMap {
                    LidAwakeOperationExecution.preview(for: .on($0))?.warning
                } ?? "")
        }
    }

    private func actionTile(
        _ tile: SurfaceTile, _ icon: String, _ title: String, active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if tile.shows("icons") {
                    Image(systemName: icon).font(.system(size: 17, weight: .medium))
                }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if tile.showDetails, !tile.dense, tile.shows("descriptions") {
                    Text(actionDetail(title)).font(.edithText(.caption2))
                        .foregroundStyle(active ? .black.opacity(0.65) : .secondary)
                        .lineLimit(2).multilineTextAlignment(.center)
                }
            }
            .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.85))
            .background(
                active ? tile.highlightColor : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.edith(.borderless)).disabled(!tile.showActions)
    }

    private func actionDetail(_ title: String) -> String {
        switch title {
        case "Clean keys": "Lock the keyboard"
        case "Keep awake": "Prevent sleep"
        case "Lid awake": "Run with the lid closed"
        case "Presenter": "Blur sensitive content"
        default: "Pick a screen color"
        }
    }

    private func emptyMusicCard(_ tile: SurfaceTile) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "music.note")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.28))
            Text("Nothing playing")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

}

private struct NotchNowPlayingCard: View {
    var controller: NotchShelfController
    let track: NotchNowPlaying
    let tile: SurfaceTile
    @Environment(\.surfacePresentation) private var presentation
    private var presenterState = PresenterState.shared
    @AppStorage(AppStorageKeys.Presenter.blurMusic, store: SharedDefaults.store)
    private var presenterBlurMusic = true

    init(controller: NotchShelfController, track: NotchNowPlaying, tile: SurfaceTile) {
        self.controller = controller
        self.track = track
        self.tile = tile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tile.showTitle {
                HStack {
                    Label(tile.displayTitle, systemImage: "music.note")
                        .font(.edithText(.caption).weight(.semibold))
                    Spacer()
                    if let icon = controller.nowPlayingAppIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                        Text(sourceName).font(.edithText(.caption2)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                if tile.shows("artwork") { artwork.disabled(!tile.showActions) }
                Button {
                    controller.openNowPlayingLocation()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.edithText(.headline)).foregroundStyle(.white)
                            .lineLimit(2).presenterBlur(presenterState.active && presenterBlurMusic)
                        if tile.showDetails, tile.shows("artist") {
                            Text(sourceLabel).font(.edithText(.caption)).foregroundStyle(.secondary)
                                .lineLimit(2).presenterBlur(
                                    presenterState.active && presenterBlurMusic)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.edith(.borderless)).disabled(!tile.showActions)
                    .help(isLocal ? "Show this track in Music" : "Open the app playing this")
            }
            Spacer(minLength: 4)
            if tile.showDetails, tile.shows("progress"), controller.nowPlayingSeekable {
                NotchSeekBar(controller: controller).allowsHitTesting(tile.showActions)
            }
            if tile.showActions {
                HStack(spacing: 24) {
                    Spacer(minLength: 0)
                    control("backward.fill", 15) { controller.nowPlayingPrevious() }
                    control(track.isPlaying ? "pause.fill" : "play.fill", 20) {
                        controller.nowPlayingPlayPause()
                    }
                    control("forward.fill", 15) { controller.nowPlayingNext() }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(presentation?.padding ?? tile.paddingOverride ?? 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            .white.opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: presentation?.cornerRadius ?? tile.cornerOverride ?? 12))
    }

    private var sourceName: String {
        switch track.source {
        case .local: "Music"
        case .external(let app): app.displayName
        }
    }

    private var isLocal: Bool {
        if case .local = track.source { return true }
        return false
    }

    private var sourceLabel: String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        switch track.source {
        case .local: parts.append("Music")
        case .external(let app): parts.append(app.displayName)
        }
        return parts.joined(separator: " · ")
    }

    private var artwork: some View {
        Button {
            controller.openNowPlayingApp()
        } label: {
            Group {
                if let image = controller.nowPlayingArtwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .presenterCover(.music)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 18)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.08))
                }
            }
            .frame(width: tile.dense ? 56 : 72, height: tile.dense ? 56 : 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.edith(.borderless))
        .help("Open player")
    }

    private func control(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium)).foregroundStyle(.white)
                .frame(width: 40, height: 36)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
    }
}

private struct NotchSeekBar: View {
    var controller: NotchShelfController
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 3)
                TimelineView(.periodic(from: MusicTick.epoch, by: 0.5)) { _ in
                    let fraction = dragFraction ?? controller.nowPlayingProgress()
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: max(3, width * min(1, fraction)), height: 3)
                }
            }
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / width, 0), 1) }
                    .onEnded { value in
                        controller.nowPlayingSeek(min(max(value.location.x / width, 0), 1))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 10)
    }
}

private struct NotchClipboardTab: View {
    var controller: NotchShelfController

    var body: some View {
        if let store = controller.clipboardStore {
            NotchClipboardList(store: store, controller: controller)
        } else {
            Text("Clipboard history is off")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NotchClipboardList: View {
    var store: ClipboardStore
    let controller: NotchShelfController

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(sortedEntries.prefix(30)) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private var sortedEntries: [ClipboardEntry] {
        store.entries.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                controller.copyClipboardEntry(entry)
            } label: {
                Text(entry.displayPreview)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            Button {
                store.togglePin(entry.id)
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(entry.pinned ? 0.9 : 0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(entry.pinned ? "Unpin" : "Pin")
            Button {
                store.delete(entry.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help("Delete")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NotchRiseFade: ViewModifier, Animatable {
    var offset: CGFloat
    var visible: Bool

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: offset).opacity(visible ? 1 : 0)
    }
}

private struct NotchAlertDropView: View {
    let alert: NotchAlert
    var controller: NotchShelfController
    let glide: Animation
    @State private var appeared = false

    var body: some View {
        let tint = Color(hex: alert.tint)
        return Button {
            controller.alertTapped(alert)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: alert.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
                    .scaleEffect(appeared ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    if let subtitle = alert.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if alert.settingsTab != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .onHover { controller.alertHover($0) }
        .onAppear {
            withAnimation(glide.delay(0.05)) { appeared = true }
        }
    }
}

extension Color {
    fileprivate init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    var controller: NotchShelfController
    let canvasSize: CGSize
    @State private var handedOffToSystemDrag = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Image(
                nsImage: thumbnail ?? fallbackIcon
            )
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .presenterCover(.shelf)
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 64)
                .presenterBlur(.shelf)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(controller.selectedIDs.contains(item.id) ? 0.2 : 0))
        )
        .contentShape(Rectangle())
        .gesture(moveOrDragOut)
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                controller.toggleSelection(item)
            } else {
                controller.open(item)
            }
        }
        .contextMenu {
            Button("Open") { controller.open(item) }
            Button("Reveal in Finder") { controller.reveal(item) }
            Button("Share") { controller.share(item) }
            Button("Delete", role: .destructive) { controller.remove(item) }
        }
        .task(id: item.name) {
            thumbnail = await controller.thumbnail(for: item)
        }
    }

    private var fallbackIcon: NSImage {
        let ext = (item.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private var moveOrDragOut: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("shelfCanvas"))
            .onChanged { value in
                guard !handedOffToSystemDrag else { return }
                if CGRect(origin: .zero, size: canvasSize).contains(value.location) {
                    controller.canvasDrag(item, to: value.location, in: canvasSize)
                } else {
                    handedOffToSystemDrag = true
                    controller.beginExternalDrag(of: item)
                }
            }
            .onEnded { _ in
                handedOffToSystemDrag = false
                controller.endCanvasDrag()
            }
    }
}
