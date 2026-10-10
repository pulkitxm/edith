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
    @State private var snapshots: [String: SurfaceSnapshot] = [:]
    @State private var actionTask: Task<Void, Never>?
    @State private var actionToken: UUID?
    @State private var error: String?
    @State private var presenterSettings = false
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
    var body: some View {
        Group {
            if music != nil || !utilities.isEmpty || missingPermissions
                || updater.updateReady != nil
            {
                VStack(spacing: UIScale.pt(8)) {
                    if let music { music }
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
                                .frame(height: UIScale.pt(28)).background(
                                    .thinMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(9))
                                )
                        }.buttonStyle(.edith(.borderless)).help("Show update options")
                    }
                    utilityRow([.system, .keepAwake])
                    utilityRow([.lidAwake, .keystrokeHighlight])
                    if utilities.contains(.presenter) {
                        HStack(spacing: 0) {
                            utility(.presenter, background: false)
                            Rectangle().fill(
                                HostSidebarUtility.presenter.isOn(snapshots["presenter"])
                                    ? Color.white.opacity(0.24) : Color.primary.opacity(0.08)
                            )
                            .frame(width: UIScale.pt(1), height: UIScale.pt(28))
                            Button {
                                presenterSettings.toggle()
                            } label: {
                                Image(systemName: "chevron.right").font(
                                    .system(size: UIScale.pt(10), weight: .semibold)
                                )
                                .frame(width: UIScale.pt(30), height: UIScale.pt(46)).contentShape(
                                    Rectangle())
                            }.buttonStyle(.edith(.borderless)).help(
                                "Choose what Presenter mode blurs"
                            )
                            .accessibilityLabel("Presenter privacy settings")
                            .popover(isPresented: $presenterSettings, arrowEdge: .leading) {
                                HostExtensionContent(
                                    marketplace: marketplace, extensionID: "presenter",
                                    location: "sidebar.utility", section: "privacy",
                                    presenter: presenter, openMarketplace: openExtensions
                                )
                                .frame(width: UIScale.pt(250), height: UIScale.pt(440))
                            }
                        }.foregroundStyle(
                            HostSidebarUtility.presenter.isOn(snapshots["presenter"])
                                ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
                        )
                        .background(
                            HostSidebarUtility.presenter.isOn(snapshots["presenter"])
                                ? AnyShapeStyle(theme) : AnyShapeStyle(.thinMaterial),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(9))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(9)))
                    }
                    if missingPermissions {
                        Button(action: openPermissions) {
                            HStack(spacing: UIScale.pt(6)) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Permissions need attention").font(
                                    .system(size: UIScale.pt(11), weight: .medium))
                                Spacer(minLength: 0)
                            }.foregroundStyle(.orange).padding(.horizontal, UIScale.pt(8)).frame(
                                height: UIScale.pt(26)
                            )
                            .background(
                                Color.orange.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
                        }.buttonStyle(.edith(.borderless)).help("Open Permissions settings")
                    }
                    if let error {
                        Text(error).font(.edithText(.caption)).foregroundStyle(.secondary)
                    }
                }.padding(UIScale.pt(10))
            }
        }
        .pageTask(id: versions, active: enabled && !versions.isEmpty, cancel: clear) {
            repeat {
                for utility in utilities {
                    let version = versions[utility.id]
                    do {
                        let snapshot = try await marketplace.surfaces.requests.snapshot(
                            providerID: utility.id, target: .home, tile: tile)
                        guard !Task.isCancelled, versions[utility.id] == version else { return }
                        snapshots[utility.id] = snapshot
                    } catch {
                        guard !Task.isCancelled else { return }
                        snapshots[utility.id] = nil
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            } while !Task.isCancelled
        }
        .pageRefresh(active: enabled, interval: { .seconds(15) }) { await permissions.refresh() }
        .onChange(of: enabled) { if !enabled { clear() } }
        .onChange(of: versions) { snapshots = snapshots.filter { versions[$0.key] != nil } }
        .onDisappear(perform: clear)
    }

    @ViewBuilder private func utilityRow(_ row: [HostSidebarUtility]) -> some View {
        let available = row.filter(utilities.contains)
        if available.count == 2 && sidebarWidth >= 220 {
            HStack(spacing: UIScale.pt(8)) { ForEach(available) { utility($0) } }
        } else {
            ForEach(available) { utility($0) }
        }
    }

    private func utility(_ value: HostSidebarUtility, background: Bool = true) -> some View {
        HostSidebarUtilityButton(
            utility: value, active: value.isOn(snapshots[value.id]), theme: theme,
            background: background,
            action: { perform(value) }
        )
        .disabled(actionTask != nil)
    }

    private func perform(_ utility: HostSidebarUtility) {
        guard actionTask == nil, enabled, visible, let version = versions[utility.id]
        else { return }
        let token = UUID(); actionToken = token; error = nil
        actionTask = Task {
            defer { if actionToken == token { actionTask = nil; actionToken = nil } }
            do {
                let current = try await marketplace.surfaces.requests.snapshot(
                    providerID: utility.id, target: .home, tile: tile)
                guard !Task.isCancelled, actionToken == token, versions[utility.id] == version,
                    let action = utility.action(in: current)
                else { return }
                let result = try await marketplace.surfaces.requests.perform(
                    providerID: utility.id, target: .home, tile: tile, snapshot: current,
                    actionID: action.id)
                guard !Task.isCancelled, actionToken == token, versions[utility.id] == version
                else { return }
                snapshots[utility.id] = result
                error = result.message
            } catch {
                guard !Task.isCancelled, actionToken == token else { return }
                self.error = "The action could not finish. Try again."
            }
        }
    }

    private func clear() {
        actionTask?.cancel(); actionTask = nil; actionToken = nil
        snapshots.removeAll(); error = nil; presenterSettings = false
    }
}

struct HostSidebarUtilityButton: View {
    let utility: HostSidebarUtility
    let active: Bool
    let theme: Color
    var background = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: UIScale.pt(4)) {
                Image(systemName: utility == .keepAwake && active ? "moon.zzz.fill" : utility.icon)
                    .font(.system(size: UIScale.pt(14))).symbolEffect(.bounce, value: active)
                Text(utility.title).font(.system(size: UIScale.pt(10), weight: .medium)).lineLimit(
                    1)
            }.frame(maxWidth: .infinity).padding(.vertical, UIScale.pt(8))
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(
                    background
                        ? (active ? AnyShapeStyle(theme) : AnyShapeStyle(.thinMaterial))
                        : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: UIScale.pt(9))
                )
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
