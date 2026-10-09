import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import UniformTypeIdentifiers

struct NotchShelfContentView: View {
    var controller: NotchShelfController
    var displayID: CGDirectDisplayID = 0
    var collapsedBase: CGSize = NotchGeometry.fallbackSize
    var isBuiltin = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .animation(glide, value: controller.leadingGlance == nil)
            .animation(glide, value: controller.glanceWingWidth)
            .animation(glide, value: isHovering)
            .onReceive(
                DistributedNotificationCenter.default().publisher(
                    for: Notification.Name(NotchWorkerIPC.Name.settingsChanged))
            ) { _ in controller.layouts.reload() }
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
            glance(controller.leadingGlance)
            Color.clear.frame(width: collapsedBase.width, height: collapsedBase.height)
            glance(controller.trailingGlance)
        }
    }

    @ViewBuilder private func glance(_ value: NotchSurfaceGlance?) -> some View {
        if let value {
            Button {
                controller.openGlance(value, on: displayID)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: value.icon)
                    Text(value.value).monospacedDigit()
                }.font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(value.urgent ? .orange : .white.opacity(0.85))
                    .frame(width: controller.glanceWingWidth, height: collapsedBase.height)
            }.buttonStyle(.edith(.borderless)).help(value.title)
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
                            controller.layouts.update(.notch) { $0 = preset.layout(for: .notch) }
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
                        controller.layouts.undo(.notch)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }.disabled(!controller.layouts.canUndo(.notch)).help("Undo layout change")
                    Button {
                        controller.layouts.redo(.notch)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }.disabled(!controller.layouts.canRedo(.notch)).help("Redo layout change")
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
                controller.openCustomization()
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
                controller.layouts.update(.notch) { layout in
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
        _ = controller.layouts.notch
        return controller.visibleTabs
    }

    @ViewBuilder private var tabContent: some View {
        switch controller.activeTab {
        case .home: NotchHomeTab(controller: controller)
        case .agents: providerTab(SurfaceTile(.agents))
        case .browser: EmptyView()
        case .files: filesCanvas
        case .clipboard: providerTab(SurfaceTile(.ability("clipboard")))
        case .audio: providerTab(SurfaceTile(.ability("audioMixer")))
        case .camera: NotchCameraTab()
        }
    }

    private func providerTab(_ tile: SurfaceTile) -> some View {
        ScrollView {
            NotchSurfaceCard(controller: controller, tile: tile)
                .padding(.horizontal, 12).padding(.bottom, 12)
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
            .opacity(controller.privacy.hides(.ability("notchShelf")) ? 0 : 1)
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 64)
                .redacted(reason: controller.privacy.hides(.ability("notchShelf")) ? .privacy : [])
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
