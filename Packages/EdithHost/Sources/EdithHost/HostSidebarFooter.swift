import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

enum HostSidebarUtility: String, CaseIterable, Identifiable {
    case system, keepAwake, lidAwake, keystrokeHighlight, presenter, micMute
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Clean keys"
        case .keepAwake: "Keep awake"
        case .lidAwake: "Lid awake"
        case .keystrokeHighlight: "Keystrokes"
        case .presenter: "Presenter mode"
        case .micMute: "Mic mute"
        }
    }
    var icon: EdithIcon {
        switch self {
        case .system: .keyboard
        case .keepAwake: .moon
        case .lidAwake: .laptop
        case .keystrokeHighlight: .keystrokeHighlight
        case .presenter: .presenter
        case .micMute: .micMute
        }
    }
    var help: String {
        switch self {
        case .system: "Lock the keyboard so you can wipe it"
        case .keepAwake: "Keep this Mac from sleeping until turned off"
        case .lidAwake: "Keep this Mac running with the lid closed"
        case .keystrokeHighlight: "Show keyboard input on screen"
        case .presenter: "Blur the private details you choose, everywhere in Edith"
        case .micMute: "Mute or unmute the microphone"
        }
    }
    func action(in snapshot: SurfaceSnapshot) -> SurfaceAction? {
        guard snapshot.providerID == id else { return nil }
        let allowed: Set<String>
        switch self {
        case .system: allowed = ["cleanKeys", "stopCleaning"]
        case .keepAwake, .keystrokeHighlight: allowed = ["enable", "disable"]
        case .lidAwake: allowed = ["on", "off"]
        case .presenter: allowed = ["start", "stop"]
        case .micMute: allowed = ["toggle"]
        }
        return snapshot.actions.first { allowed.contains($0.id) }
    }
    func isOn(_ snapshot: SurfaceSnapshot?) -> Bool {
        guard let snapshot, let action = action(in: snapshot) else { return false }
        if self == .micMute {
            return snapshot.metrics.first { $0.id == "status" }?.value == "Muted"
        }
        return ["stopCleaning", "disable", "off", "stop"].contains(action.id)
    }
}

struct HostSidebarFooter: View {
    let marketplace: HostMarketplace
    let updater: HostUpdater
    let permissions: HostPermissions
    let theme: Color
    let sidebarWidth: Double
    let presenter: (any HostExtensionContentPresenting)?
    let openExtensions: () -> Void
    let openPermissions: () -> Void
    var enabled = true
    var music: AnyView? = nil
    @State private var actions = HostUtilityActions()
    @State private var presenterSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tile = SurfaceTile(.actions)
    @Environment(\.windowVisible) private var visible

    private var active: Set<String> { marketplace.surfaceAvailability.activeIDs }
    private var versions: [String: String] {
        marketplace.sessions.versions.filter {
            active.contains($0.key) && HostSidebarUtility(rawValue: $0.key) != nil
        }
    }
    private var missingPermissions: Bool {
        HostPermissionCatalog.usages(
            entries: marketplace.entries, activeIDs: active, granted: permissions.granted
        )
        .contains { $0.blocksEnabledExtension }
    }
    private var utilities: [HostSidebarUtility] {
        HostSidebarUtility.allCases.filter { $0 != .micMute && versions[$0.id] != nil }
    }
    private var populated: Bool {
        music != nil || !utilities.isEmpty || missingPermissions || updater.updateReady != nil
    }
    var body: some View {
        Group {
            if populated {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: UIScale.pt(1))
                    VStack(spacing: UIScale.pt(8)) {
                        if let music {
                            music.transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if let version = updater.updateReady {
                            HostSidebarNotice(
                                icon: .arrowDown, title: "Update ready",
                                detail: "v\(version)", tint: DashSkin.sage,
                                action: updater.checkForUpdates
                            ).help("Show update options")
                        }
                        utilityRow([.system, .keepAwake])
                        utilityRow([.lidAwake, .keystrokeHighlight])
                        if utilities.contains(.presenter) {
                            HStack(spacing: UIScale.pt(6)) {
                                utility(.presenter)
                                Button {
                                    presenterSettings.toggle()
                                } label: {
                                    EdithIconView(.adjust)
                                        .font(.edithText(.caption))
                                        .frame(
                                            width: UIScale.pt(30),
                                            height: HostSidebarUtilityButton.height
                                        )
                                        .background(
                                            Color.primary.opacity(0.05),
                                            in: RoundedRectangle(
                                                cornerRadius: HostSidebarUtilityButton.radius)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.edith(.borderless))
                                .foregroundStyle(.secondary)
                                .help("Choose what Presenter mode blurs")
                                .accessibilityLabel("Presenter privacy settings")
                                .popover(isPresented: $presenterSettings, arrowEdge: .leading) {
                                    HostExtensionContent(
                                        marketplace: marketplace, extensionID: "presenter",
                                        location: "sidebar.utility", section: "privacy",
                                        presenter: presenter, openMarketplace: openExtensions,
                                        initialHeight: UIScale.pt(220)
                                    )
                                    .frame(width: UIScale.pt(250))
                                    .frame(maxHeight: UIScale.pt(440))
                                }
                            }
                        }
                        if missingPermissions {
                            HostSidebarNotice(
                                icon: .warning,
                                title: "Permissions needed", tint: DashSkin.warn,
                                action: openPermissions
                            ).help("Open Permissions settings")
                        }
                    }.padding(UIScale.pt(10))
                }.transition(utilityTransition)
            }
        }
        .animation(Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: populated)
        .animation(
            Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: music != nil
        )
        .animation(
            Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: utilities
        )
        .hostUtilityAlerts(actions, marketplace: marketplace, tile: tile) { id in versions[id] }
        .pageTask(id: versions, active: enabled && !versions.isEmpty, cancel: actions.clear) {
            await actions.poll(
                utilities: utilities, marketplace: marketplace, tile: tile, versions: { versions })
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name("edith.lidAwakeChanged"))
        ) { _ in actions.refreshTick += 1 }
        .pageRefresh(active: enabled, interval: { .seconds(15) }) { await permissions.refresh() }
        .onChange(of: enabled) { if !enabled { clear() } }
        .onChange(of: versions) {
            actions.snapshots = actions.snapshots.filter { versions[$0.key] != nil }
        }
        .onDisappear(perform: clear)
    }

    private var utilityTransition: AnyTransition {
        Motion.transition(
            .move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion,
            preferCrossFade: false)
    }

    @ViewBuilder private func utilityRow(_ row: [HostSidebarUtility]) -> some View {
        let available = row.filter(utilities.contains)
        if available.count == 2 && sidebarWidth >= 220 {
            HStack(spacing: UIScale.pt(6)) { ForEach(available) { utility($0) } }
                .transition(utilityTransition)
        } else {
            ForEach(available) { utility($0).transition(utilityTransition) }
        }
    }

    private func utility(_ value: HostSidebarUtility) -> some View {
        HostSidebarUtilityButton(
            utility: value,
            active: value != .system && actions.isOn(value),
            theme: theme,
            action: { perform(value) }
        )
    }

    private func perform(_ utility: HostSidebarUtility) {
        guard enabled, visible, let version = versions[utility.id] else { return }
        actions.perform(
            utility, marketplace: marketplace, tile: tile, version: version,
            current: { versions[utility.id] })
    }

    private func clear() {
        actions.clear(); presenterSettings = false
    }
}

extension View {
    func hostUtilityAlerts(
        _ actions: HostUtilityActions, marketplace: HostMarketplace, tile: SurfaceTile,
        version: @escaping @MainActor (String) -> String?
    ) -> some View {
        modifier(
            HostUtilityAlerts(
                actions: actions, marketplace: marketplace, tile: tile, version: version))
    }
}

private struct HostUtilityAlerts: ViewModifier {
    @Bindable var actions: HostUtilityActions
    let marketplace: HostMarketplace
    let tile: SurfaceTile
    let version: @MainActor (String) -> String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Lid Awake could not change state",
                isPresented: Binding(
                    get: { actions.lidAwakeError != nil },
                    set: { if !$0 { actions.lidAwakeError = nil } })
            ) {
                Button("OK") { actions.lidAwakeError = nil }
            } message: {
                Text(actions.lidAwakeError ?? "")
            }
            .alert(
                actions.confirmation?.action.confirmation?.title ?? "",
                isPresented: Binding(
                    get: { actions.confirmation != nil },
                    set: { if !$0 { actions.confirmation = nil } }),
                presenting: actions.confirmation
            ) { pending in
                Button(pending.action.confirmation?.confirmTitle ?? "OK") {
                    let utility = pending.utility
                    actions.run(
                        utility, action: pending.action, snapshot: pending.snapshot,
                        marketplace: marketplace, tile: tile, version: pending.version,
                        current: { version(utility.id) })
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.action.confirmation?.message ?? "")
            }
    }
}

struct HostSidebarUtilityButton: View {
    static var height: CGFloat { UIScale.pt(30) }
    static var radius: CGFloat { UIScale.pt(8) }
    let utility: HostSidebarUtility
    let active: Bool
    let theme: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(7)) {
                EdithIconView(utility.icon)
                    .font(.edithText(.caption))
                    .frame(width: UIScale.pt(16))
                Text(utility.title).font(.edithText(.caption).weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(9))
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .foregroundStyle(active ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary))
            .background(
                active ? theme.opacity(0.16) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: Self.radius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless)).help(utility.help).accessibilityLabel(utility.title)
        .accessibilityValue(utility == .system ? "" : (active ? "On" : "Off"))
    }
}

struct HostSidebarNotice: View {
    let icon: EdithIcon
    let title: String
    var detail: String? = nil
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(7)) {
                EdithIconView(icon).frame(width: UIScale.pt(16))
                Text(title).fontWeight(.medium).lineLimit(1)
                if let detail { Text(detail).opacity(0.75).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .font(.edithText(.caption))
            .foregroundStyle(tint)
            .padding(.horizontal, UIScale.pt(9))
            .frame(minHeight: HostSidebarUtilityButton.height)
            .background(
                tint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: HostSidebarUtilityButton.radius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }
}

struct HostAgentStatusBar: View {
    let online: Bool
    let summary: String
    let openSettings: () -> Void
    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: UIScale.pt(7)) {
                Circle().fill(online ? DashSkin.sage : Color.orange).frame(
                    width: UIScale.pt(6), height: UIScale.pt(6))
                Text("background").font(DashSkin.mono(10, weight: .semibold)).foregroundStyle(
                    .secondary)
                Text(summary).font(DashSkin.mono(10)).foregroundStyle(.tertiary).lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }.padding(.horizontal, UIScale.pt(11)).frame(height: UIScale.pt(24)).contentShape(
                Rectangle())
        }.buttonStyle(.edith(.borderless)).help("Open Background agent settings")
            .accessibilityLabel("Background agent").accessibilityValue(summary)
    }
}
