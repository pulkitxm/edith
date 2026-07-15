import AppKit
import EdithKit
import SwiftUI

extension View {
    func shelfPointer() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

struct NotchShelfContentView: View {
    @ObservedObject var controller: NotchShelfController
    var collapsedBase: CGSize = NotchGeometry.fallbackSize
    var isBuiltin = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabPill

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                layers
                    .scaleEffect(
                        x: 1 / hoverScale.width, y: 1 / hoverScale.height, anchor: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask {
                CenteredNotchShape(
                    width: shapeSize.width, height: shapeSize.height,
                    topRadius: topRadius, bottomRadius: bottomRadius)
            }
            .scaleEffect(x: hoverScale.width, y: hoverScale.height, anchor: .top)
            .animation(glide, value: controller.isExpanded)
            .animation(glide, value: controller.currentAlert)
            .animation(glide, value: controller.activeTab)
            .animation(glide, value: controller.nowPlaying == nil)
            .animation(glide, value: controller.collapsedHover)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    controller.hoverChanged(hoverRect(in: geo.size).contains(point))
                case .ended:
                    controller.hoverChanged(false)
                }
            }
        }
    }

    @ViewBuilder private var layers: some View {
        if controller.isExpanded {
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
                base: collapsedBase, hasLiveActivity: controller.nowPlaying != nil)
            collapsed
                .frame(width: size.width, height: size.height)
                .transition(collapsedTransition)
        }
    }

    private var expandedShape: CGSize {
        NotchGeometry.expandedShapeSize(
            tab: controller.activeTab, hasMusic: controller.nowPlaying != nil,
            notchHeight: collapsedBase.height)
    }

    private var shapeSize: CGSize {
        if controller.isExpanded { return expandedShape }
        if isBuiltin, controller.currentAlert != nil { return NotchGeometry.alertDropSize }
        return NotchGeometry.collapsedSize(
            base: collapsedBase, hasLiveActivity: controller.nowPlaying != nil)
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

    private var hoverScale: CGSize {
        guard !reduceMotion, controller.collapsedHover, !controller.isExpanded,
            controller.currentAlert == nil
        else { return CGSize(width: 1, height: 1) }
        let shape = shapeSize
        return CGSize(
            width: 1 + NotchGeometry.hoverGrow / shape.width,
            height: 1 + NotchGeometry.hoverGrow / shape.height)
    }

    private var topRadius: CGFloat {
        controller.isExpanded || (isBuiltin && controller.currentAlert != nil)
            ? NotchGeometry.expandedTopRadius : 0
    }

    private var bottomRadius: CGFloat {
        if isBuiltin, controller.currentAlert != nil, !controller.isExpanded {
            return NotchGeometry.alertBottomRadius
        }
        return controller.isExpanded
            ? NotchGeometry.expandedBottomRadius : NotchGeometry.collapsedBottomRadius
    }

    private var glide: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.9)
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    @ViewBuilder private var collapsed: some View {
        if let track = controller.nowPlaying {
            NotchMusicWings(controller: controller, track: track)
        } else if !controller.items.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                Text("\(controller.items.count)")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var expanded: some View {
        VStack(spacing: 6) {
            header
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, collapsedBase.height)
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(visibleTabs, id: \.self) { tab in
                iconTab(tab)
            }
            Spacer(minLength: 0)
            Button {
                controller.collapseNow()
                MainApp.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 32, height: 22)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).shelfPointer()
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
                if active {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, active ? 10 : 8)
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
        .buttonStyle(.plain).shelfPointer()
        .help(tab.title)
    }

    private var visibleTabs: [NotchTab] {
        let mixerOn = SharedDefaults.store.bool(forKey: "notchAudioMixerEnabled")
        return NotchTab.allCases.filter { $0 != .audio || mixerOn }
    }

    @ViewBuilder private var tabContent: some View {
        switch controller.activeTab {
        case .home: NotchHomeTab(controller: controller)
        case .files: filesCanvas
        case .clipboard: NotchClipboardTab(controller: controller)
        case .audio: NotchAudioTab()
        case .camera: NotchCameraTab()
        }
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
            }
            .coordinateSpace(name: "shelfCanvas")
        }
    }
}

private struct NotchHomeTab: View {
    @ObservedObject var controller: NotchShelfController
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenterMode = false
    @AppStorage("presenterEnabled", store: SharedDefaults.store) private var presenterEnabled =
        true
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("notchShelfShowMusic", store: SharedDefaults.store) private var showMusic = true

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if let track = controller.nowPlaying {
                    NotchNowPlayingCard(controller: controller, track: track)
                } else if showMusic, controller.usageStore != nil {
                    emptyMusicCard
                }
                if let usage = controller.usageStore {
                    ringsCard(usage)
                }
                if controller.nowPlaying == nil, controller.usageStore == nil {
                    Text("Nothing to show yet")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if systemEnabled || presenterEnabled || controller.canPickColor {
                quickActions
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            if systemEnabled {
                actionTile("keyboard", "Clean keys", active: false) {
                    controller.cleanKeyboard()
                }
                actionTile(
                    preventSleep ? "moon.zzz.fill" : "moon.zzz", "Keep awake", active: preventSleep
                ) {
                    preventSleep.toggle()
                    controller.collapseNow()
                }
            }
            if presenterEnabled {
                actionTile("person.wave.2", "Presenter", active: presenterMode) {
                    presenterMode.toggle()
                    if !presenterMode { IPC.post(IPC.Name.presenterPauseAuto) }
                    controller.collapseNow()
                }
            }
            if controller.canPickColor {
                actionTile("eyedropper", "Pick color", active: false) {
                    controller.pickColor()
                }
            }
        }
    }

    private func actionTile(
        _ icon: String, _ title: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.85))
            .background(
                active
                    ? Color(red: 0.79, green: 0.56, blue: 0.31) : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).shelfPointer()
    }

    private var emptyMusicCard: some View {
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

    private func ringsCard(_ usage: UsageStore) -> some View {
        NotchUsageRings(usage: usage)
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NotchNowPlayingCard: View {
    @ObservedObject var controller: NotchShelfController
    let track: NotchNowPlaying
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store)
    private var presenterBlurMusic = true

    var body: some View {
        HStack(spacing: 11) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white).lineLimit(1)
                            .presenterBlur(presenterState.active && presenterBlurMusic)
                        Text(sourceLabel)
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .presenterBlur(presenterState.active && presenterBlurMusic)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        control("backward.fill", 12) { controller.nowPlayingPrevious() }
                        control(track.isPlaying ? "pause.fill" : "play.fill", 15) {
                            controller.nowPlayingPlayPause()
                        }
                        control("forward.fill", 12) { controller.nowPlayingNext() }
                    }
                }
                if controller.nowPlayingSeekable {
                    NotchSeekBar(controller: controller)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
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
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 18)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.08))
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.plain).shelfPointer()
        .help("Open player")
    }

    private func control(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).shelfPointer()
    }
}

private struct NotchSeekBar: View {
    @ObservedObject var controller: NotchShelfController
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

private struct NotchUsageRings: View {
    @ObservedObject var usage: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("limitsProvider", store: SharedDefaults.store) private var selectedRaw =
        LimitProvider.claude.rawValue
    @State private var drawn = false

    private var providers: [LimitProvider] { usage.availableProviders }
    private var selected: LimitProvider {
        get {
            let saved = LimitProvider(rawValue: selectedRaw) ?? .claude
            return providers.contains(saved) ? saved : providers.first ?? saved
        }
        nonmutating set { selectedRaw = newValue.rawValue }
    }

    private var limits: ProviderLimits { usage.limits(for: selected) }

    var body: some View {
        HStack(spacing: 20) {
            ring("5h", limits.session)
            ring("7d", limits.week)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            ProviderSwitchButton(
                selection: Binding(get: { selected }, set: { selected = $0 }),
                providers: providers, color: .white.opacity(0.72), size: 14
            )
            .padding(8)
        }
        .overlay(alignment: .topTrailing) { refreshButton.padding(6) }
        .onAppear {
            guard !reduceMotion else {
                drawn = true
                return
            }
            withAnimation(.easeOut(duration: 0.8).delay(0.25)) { drawn = true }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await usage.refreshLimits(force: true) }
        } label: {
            Group {
                if usage.refreshingLimits {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).shelfPointer()
        .disabled(usage.refreshingLimits)
        .help("Refresh limits now")
    }

    private func ring(_ label: String, _ window: LimitWindow?) -> some View {
        let value = window?.percent ?? 0
        return VStack(spacing: 0) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 4.5)
                Circle()
                    .trim(from: 0, to: drawn ? min(1, value / 100) : 0)
                    .stroke(color(value), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 7)
            resetLabel(window?.resetsAt)
                .padding(.top, 2)
        }
    }

    @ViewBuilder private func resetLabel(_ resetsAt: Date?) -> some View {
        if let reset = resetsAt, reset > Date() {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(countdown(from: context.date, to: reset))
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        } else {
            Text(" ").font(.system(size: 9))
        }
    }

    private func countdown(from now: Date, to reset: Date) -> String {
        let s = max(0, Int(reset.timeIntervalSince(now)))
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if d > 0 { return String(format: "%dd %d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func color(_ percent: Double) -> Color {
        if percent >= 85 { return Color(red: 0.88, green: 0.4, blue: 0.31) }
        if percent >= 60 { return Color(red: 0.88, green: 0.66, blue: 0.25) }
        return Color(red: 0.3, green: 0.77, blue: 0.49)
    }
}

private struct NotchClipboardTab: View {
    @ObservedObject var controller: NotchShelfController

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
    @ObservedObject var store: ClipboardStore
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
                Text(entry.preview ?? "Non-text item")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).shelfPointer()
            Button {
                store.togglePin(entry.id)
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(entry.pinned ? 0.9 : 0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).shelfPointer()
            .help(entry.pinned ? "Unpin" : "Pin")
            Button {
                store.delete(entry.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).shelfPointer()
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
    @ObservedObject var controller: NotchShelfController
    let glide: Animation
    @State private var appeared = false

    var body: some View {
        let tint = Color(hex: alert.tint)
        return HStack(spacing: 11) {
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { controller.alertHover($0) }
        .onTapGesture { controller.dismissAlert() }
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

private struct NotchMusicWings: View {
    @ObservedObject var controller: NotchShelfController
    let track: NotchNowPlaying
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            artwork
                .frame(width: NotchGeometry.musicWingWidth)
            Spacer(minLength: 0)
            PlaybackWave(playing: track.isPlaying, color: .white.opacity(0.85), barCount: 4)
                .frame(width: NotchGeometry.musicWingWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceKey: String { String(describing: track.source) }

    private var artwork: some View {
        ZStack {
            wingIcon
                .id(sourceKey)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity))
        }
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.9),
            value: sourceKey
        )
        .clipped()
    }

    @ViewBuilder private var wingIcon: some View {
        if let image = controller.nowPlayingArtwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var controller: NotchShelfController
    let canvasSize: CGSize
    @State private var handedOffToSystemDrag = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Image(
                nsImage: thumbnail
                    ?? NSWorkspace.shared.icon(forFile: controller.fileURL(for: item).path)
            )
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 64)
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
            thumbnail = await ShelfThumbnails.thumbnail(for: controller.fileURL(for: item))
        }
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
