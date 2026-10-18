import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

enum HostSidebarUtility: String, CaseIterable, Identifiable {
    case system, keepAwake, lidAwake, keystrokeHighlight, presenter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Clean keys"
        case .keepAwake: "Keep awake"
        case .lidAwake: "Lid awake"
        case .keystrokeHighlight: "Keystrokes"
        case .presenter: "Presenter mode"
        }
    }
    var icon: String {
        switch self {
        case .system: "keyboard"
        case .keepAwake: "moon.zzz"
        case .lidAwake: "laptopcomputer"
        case .keystrokeHighlight: "keyboard.badge.ellipsis"
        case .presenter: "theatermasks.fill"
        }
    }
    var help: String {
        switch self {
        case .system: "Lock the keyboard so you can wipe it"
        case .keepAwake: "Keep this Mac from sleeping until turned off"
        case .lidAwake: "Keep this Mac running with the lid closed"
        case .keystrokeHighlight: "Show keyboard input on screen"
        case .presenter: "Blur the private details you choose, everywhere in Edith"
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
        }
        return snapshot.actions.first { allowed.contains($0.id) }
    }
    func isOn(_ snapshot: SurfaceSnapshot?) -> Bool {
        guard let snapshot, let action = action(in: snapshot) else { return false }
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
    @AppStorage(AppStorageKeys.General.preventSleep, store: SharedDefaults.store)
    private var preventSleep = false
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
        HostSidebarUtility.allCases.filter { versions[$0.id] != nil }
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
                            Button {
                                updater.checkForUpdates()
                            } label: {
                                HStack(spacing: UIScale.pt(6)) {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Update ready").font(
                                        .system(size: UIScale.pt(11.5), weight: .semibold))
                                    Text("v\(version)").font(
                                        .system(size: UIScale.pt(10.5), weight: .medium)
                                    ).opacity(0.75)
                                    Spacer(minLength: 0)
                                }.foregroundStyle(DashSkin.sage).padding(.horizontal, UIScale.pt(9))
                                    .frame(height: UIScale.pt(28)).background {
                                        SkeuoKey(.raised, cornerRadius: 9)
                                    }
                            }.buttonStyle(.edith(.borderless)).help("Show update options")
                        }
                        utilityRow([.system, .keepAwake])
                        utilityRow([.lidAwake, .keystrokeHighlight])
                        if utilities.contains(.presenter) {
                            HStack(spacing: 0) {
                                utility(.presenter, background: false)
                                Rectangle().fill(
                                    actions.isOn(.presenter, preventSleep: preventSleep)
                                        ? Color.white.opacity(0.24) : Color.primary.opacity(0.08)
                                )
                                .frame(width: UIScale.pt(1), height: UIScale.pt(28))
                                Button {
                                    presenterSettings.toggle()
                                } label: {
                                    Image(systemName: "chevron.right").font(
                                        .system(size: UIScale.pt(10), weight: .semibold)
                                    )
                                    .symbolEffect(.bounce, value: presenterSettings)
                                    .frame(width: UIScale.pt(30), height: UIScale.pt(46))
                                    .contentShape(
                                        Rectangle())
                                }.buttonStyle(.edith(.borderless)).help(
                                    "Choose what Presenter mode blurs"
                                )
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
                            }.foregroundStyle(
                                actions.isOn(.presenter, preventSleep: preventSleep)
                                    ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
                            )
                            .background {
                                let on = actions.isOn(.presenter, preventSleep: preventSleep)
                                SkeuoKey(on ? .pressed : .raised, cornerRadius: 9, tint: on ? theme : nil)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(9)))
                        }
                        if missingPermissions {
                            Button(action: openPermissions) {
                                HStack(spacing: UIScale.pt(6)) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("Permissions need attention").font(
                                        .system(size: UIScale.pt(11), weight: .medium))
                                    Spacer(minLength: 0)
                                }.foregroundStyle(.orange).padding(.horizontal, UIScale.pt(8))
                                    .frame(
                                        height: UIScale.pt(26)
                                    )
                                    .background(
                                        Color.orange.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
                            }.buttonStyle(.edith(.borderless)).help("Open Permissions settings")
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
            HStack(spacing: UIScale.pt(8)) { ForEach(available) { utility($0) } }
                .transition(utilityTransition)
        } else {
            ForEach(available) { utility($0).transition(utilityTransition) }
        }
    }

    private func utility(_ value: HostSidebarUtility, background: Bool = true) -> some View {
        HostSidebarUtilityButton(
            utility: value,
            active: value != .system && actions.isOn(value, preventSleep: preventSleep),
            theme: theme,
            background: background,
            action: { perform(value) }
        )
    }

    private func perform(_ utility: HostSidebarUtility) {
        guard enabled, visible, let version = versions[utility.id] else { return }
        actions.perform(
            utility, marketplace: marketplace, tile: tile, version: version,
            preventSleep: preventSleep, current: { versions[utility.id] })
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
    let utility: HostSidebarUtility
    let active: Bool
    let theme: Color
    var background = true
    let action: () -> Void
    @State private var clicks = 0
    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            VStack(spacing: UIScale.pt(4)) {
                Image(systemName: utility == .keepAwake && active ? "moon.zzz.fill" : utility.icon)
                    .font(.system(size: UIScale.pt(14)))
                    .symbolEffect(.bounce, value: utility == .system ? clicks : (active ? 1 : 0))
                Text(utility.title).font(.system(size: UIScale.pt(10), weight: .medium)).lineLimit(
                    1)
            }.frame(maxWidth: .infinity).padding(.vertical, UIScale.pt(8))
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background {
                    if background {
                        SkeuoKey(active ? .pressed : .raised, cornerRadius: 9, tint: active ? theme : nil)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.edith(.borderless)).help(utility.help).accessibilityLabel(utility.title)
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
                Text("edithd").font(DashSkin.mono(10, weight: .semibold)).foregroundStyle(
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
