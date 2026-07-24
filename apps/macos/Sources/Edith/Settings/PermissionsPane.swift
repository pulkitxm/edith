import AppKit
import EdithKit
import SwiftUI

struct PermissionsPane: View {
    @AppStorage("permissionsFilter", store: SharedDefaults.store) private var filterRaw =
        PermissionFilter.mine.rawValue
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @State private var usages: [PermissionUsage] = PermissionsStatus.usages
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactLayout) private var compact

    private var accent: Color { themeColor(themeName) }

    private var filter: PermissionFilter {
        PermissionFilter(rawValue: filterRaw) ?? .mine
    }

    private var visible: [PermissionUsage] {
        PermissionCatalog.filter(usages, by: filter)
    }

    private var pending: [PermissionUsage] {
        PermissionCatalog.grantable(usages)
    }

    private var granted: [PermissionUsage] {
        visible.filter(\.isGranted)
    }

    private var ungranted: [PermissionUsage] {
        visible.filter { !$0.isGranted }
            .sorted { $0.blocksEnabledExtension && !$1.blocksEnabledExtension }
    }

    @ViewBuilder
    private func section(_ title: String, usages sectionUsages: [PermissionUsage]) -> some View {
        if !sectionUsages.isEmpty {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                HStack(spacing: UIScale.pt(6)) {
                    eyebrow(title)
                    Text("\(sectionUsages.count)")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                ForEach(sectionUsages) { usage in
                    PermissionCard(usage: usage, grant: grant)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            summary
            filterRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    section("NOT GRANTED", usages: ungranted)
                    section("GRANTED", usages: granted)
                    if visible.isEmpty {
                        emptyState
                    }
                }
                .pageContent(compact)
                .animation(
                    Motion.animation(Motion.snap, reduceMotion: reduceMotion),
                    value: granted.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Permissions")
        .onAppear(perform: refresh)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refresh()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.permissionsRefreshed)
        ) { _ in
            usages = PermissionsStatus.usages
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: UIScale.pt(14)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(headline)
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                Text(
                    "Grant access here once and every extension that needs it works straight away, with no prompt mid-task."
                )
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !pending.isEmpty {
                Button("Grant \(pending.count) Remaining") {
                    for usage in pending { grant(usage) }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .pointerCursor()
            }
        }
        .pageGutter(compact)
    }

    private var headline: String {
        let needed = usages.filter(\.isUsedByEnabledExtension)
        guard !needed.isEmpty else { return "No enabled extension needs access yet" }
        let granted = PermissionCatalog.grantedCount(needed)
        return "\(granted) of \(needed.count) granted for your extensions"
    }

    private var filterRow: some View {
        HStack(spacing: UIScale.pt(8)) {
            ForEach(PermissionFilter.allCases, id: \.self) { item in
                Button {
                    withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                        filterRaw = item.rawValue
                    }
                } label: {
                    HStack(spacing: UIScale.pt(5)) {
                        Text(item.rawValue)
                        if item == .attention, attentionCount > 0 {
                            Text("\(attentionCount)")
                                .padding(.horizontal, UIScale.pt(5))
                                .background(
                                    filter == item ? Color.white.opacity(0.25) : Color.red,
                                    in: Capsule()
                                )
                                .foregroundStyle(Color.white)
                        }
                    }
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .foregroundStyle(filter == item ? Color.white : Color.secondary)
                    .padding(.horizontal, UIScale.pt(12))
                    .frame(height: UIScale.pt(28))
                    .background(filter == item ? accent : Color.clear)
                    .clipShape(Capsule())
                    .overlay {
                        if filter != item {
                            Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.65))
                        }
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer(minLength: 0)
        }
        .pageGutter(compact)
    }

    private var attentionCount: Int {
        usages.filter(\.blocksEnabledExtension).count
    }

    private var emptyState: some View {
        VStack(spacing: UIScale.pt(6)) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: UIScale.pt(26)))
                .foregroundStyle(.green)
            Text(
                filter == .attention
                    ? "Everything your extensions need is granted."
                    : "Turn on an extension to see the access it needs."
            )
            .font(.system(size: UIScale.pt(12)))
            .foregroundStyle(.secondary)
            Button("Browse Extensions") {
                mainWindowSection = MainDestination.extensions.rawValue
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(40))
    }

    private func grant(_ usage: PermissionUsage) {
        if usage.permission == .calendar {
            CalendarPermission.request()
            return
        }
        guard let request = usage.permission.grantRequest else { return }
        IPC.post(request)
    }

    private func refresh() {
        CalendarPermission.mirror()
        usages = PermissionsStatus.usages
        IPC.post(IPC.Name.requestPermissionsRefresh)
    }
}

private struct PermissionCard: View {
    let usage: PermissionUsage
    let grant: (PermissionUsage) -> Void

    private var permission: ExtensionPermission { usage.permission }

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Image(systemName: permission.symbolName)
                .font(.system(size: UIScale.pt(16), weight: .medium))
                .foregroundStyle(usage.isGranted ? .green : .secondary)
                .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                .background(
                    (usage.isGranted ? Color.green : Color.secondary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(10), style: .continuous))
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                HStack(spacing: UIScale.pt(8)) {
                    Text(permission.displayName)
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    statusBadge
                    Spacer(minLength: 0)
                    action
                }
                Text(permission.firstUseExplanation ?? permission.reason)
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !usage.users.isEmpty {
                    usedByRow
                }
            }
        }
        .padding(UIScale.pt(14))
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
                .stroke(
                    usage.blocksEnabledExtension
                        ? Color.orange.opacity(0.6)
                        : Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if usage.isGranted {
            badge("Granted", color: .green)
        } else if usage.blocksEnabledExtension {
            badge("Needed now", color: .orange)
        } else if usage.grantsOnFirstUse {
            badge("On first use", color: .secondary)
        } else {
            badge("Not granted", color: .secondary)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(10), weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, UIScale.pt(7))
            .padding(.vertical, UIScale.pt(2))
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder private var action: some View {
        if !usage.isGranted, permission.grantRequest != nil {
            Button("Grant...") { grant(usage) }
                .pointerCursor()
        }
    }

    private var usedByRow: some View {
        HStack(spacing: UIScale.pt(6)) {
            ForEach(usage.users) { entry in
                let enabled = usage.enabledUsers.contains(entry)
                let required = usage.requiredBy.contains(entry)
                HStack(spacing: UIScale.pt(4)) {
                    Image(systemName: entry.symbolName)
                    Text(entry.title)
                    if required {
                        Text("required")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .padding(.horizontal, UIScale.pt(7))
                .padding(.vertical, UIScale.pt(3))
                .background(
                    Color(nsColor: .separatorColor).opacity(enabled ? 0.35 : 0.15), in: Capsule())
            }
        }
    }
}
