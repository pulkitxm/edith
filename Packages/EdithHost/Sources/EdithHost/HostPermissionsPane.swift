import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostPermissionsPane: View {
    @AppStorage(AppStorageKeys.Permissions.filter, store: SharedDefaults.store) private
        var filterRaw =
        HostPermissionFilter.mine.rawValue
    let marketplace: HostMarketplace
    let permissions: HostPermissions
    var openExtensions: () -> Void = {}

    var body: some View {
        HostPermissionsList(
            usages: permissions.usages(
                entries: marketplace.entries, activeIDs: marketplace.surfaceAvailability.activeIDs),
            permissions: permissions,
            filter: Binding(
                get: { HostPermissionFilter(rawValue: filterRaw) ?? .mine },
                set: { filterRaw = $0.rawValue }),
            openExtensions: openExtensions
        )
        .pageTask(id: marketplace.surfaceAvailability.activeIDs.sorted()) {
            await permissions.watch(interval: .seconds(2))
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await permissions.refresh() }
        }
    }
}

struct HostPermissionsList: View {
    let usages: [HostPermissionUsage]
    let permissions: HostPermissions
    @Binding var filter: HostPermissionFilter
    var openExtensions: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    private var visible: [HostPermissionUsage] { HostPermissionCatalog.filter(usages, by: filter) }
    private var pending: [HostPermissionUsage] { HostPermissionCatalog.grantable(usages) }
    private var granted: [HostPermissionUsage] { visible.filter(\.isGranted) }
    private var ungranted: [HostPermissionUsage] {
        visible.filter { !$0.isGranted }
            .sorted { $0.blocksEnabledExtension && !$1.blocksEnabledExtension }
    }
    private var attentionCount: Int { usages.filter(\.blocksEnabledExtension).count }

    private var columns: [GridItem] {
        PageMetrics.cardColumns(compact, minimum: 360, spacing: 12, alignment: .top)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            summary
            if !permissions.awaitingRelaunch.isEmpty { relaunchBanner }
            filterRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    section("Not allowed", usages: ungranted)
                    section("Allowed", usages: granted)
                    if visible.isEmpty { emptyState }
                }
                .padding(.top, UIScale.pt(4))
                .pageContent(compact)
                .animation(
                    Motion.animation(Motion.snap, reduceMotion: reduceMotion),
                    value: granted.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Permissions")
    }

    @ViewBuilder
    private func section(_ title: String, usages sectionUsages: [HostPermissionUsage]) -> some View
    {
        if !sectionUsages.isEmpty {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                HStack(spacing: UIScale.pt(8)) {
                    PageCapsLabel(title)
                    Text("\(sectionUsages.count)")
                        .font(PageMetrics.capsFont).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(12)) {
                    ForEach(sectionUsages) { usage in
                        HostPermissionCard(
                            usage: usage,
                            awaitingRelaunch: permissions.awaitingRelaunch.contains(
                                usage.permission),
                            grant: grant)
                    }
                }
            }
        }
    }

    private var summary: some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(16)))
        return layout {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(headline).font(.edithText(.headline)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Allow access here once and every tool that needs it works straight away, with no prompt in the middle of a task."
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !pending.isEmpty {
                Button("Allow next (\(pending.count) left)") {
                    if let next = pending.first { grant(next) }
                }
                .buttonStyle(.edith(.primary))
                .disabled(permissions.requesting != nil)
                .fixedSize()
            }
        }
        .pageGutter(compact)
    }

    private var relaunchBanner: some View {
        let names = HostPermission.allCases.filter { permissions.awaitingRelaunch.contains($0) }
            .map(\.displayName).joined(separator: " and ")
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(16)))
        return layout {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                HostOnboardingIcon(symbolName: "arrow.clockwise", size: 32)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Relaunch once to finish \(names)")
                        .font(.edithText(.headline))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Turn the switch on in System Settings first, then relaunch Edith.")
                        .font(.edithText(.callout)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Relaunch Edith") { permissions.relaunch() }
                .buttonStyle(.edith(pending.isEmpty ? .primary : .secondary))
                .fixedSize()
                .padding(.leading, compact ? UIScale.pt(44) : 0)
                .accessibilityIdentifier("permissions.relaunch")
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostOnboardingTile(highlighted: true)
        .pageGutter(compact)
    }

    private var headline: String {
        let needed = usages.filter(\.isUsedByEnabledExtension)
        guard !needed.isEmpty else { return "No enabled extension needs access yet" }
        let granted = HostPermissionCatalog.grantedCount(needed)
        return "\(granted) of \(needed.count) allowed for your tools"
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(8)) {
                ForEach(HostPermissionFilter.allCases, id: \.self) { item in
                    Button {
                        withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                            filter = item
                        }
                    } label: {
                        HStack(spacing: UIScale.pt(6)) {
                            Text(item.rawValue).lineLimit(1)
                            if item == .attention, attentionCount > 0 {
                                Text("\(attentionCount)")
                                    .font(.edithText(.caption2)).fontWeight(.semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, UIScale.pt(6))
                                    .background(DashSkin.warn, in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(.pageChip(active: filter == item))
                    .fixedSize()
                    .accessibilityLabel(item.rawValue)
                }
            }
        }
        .pageGutter(compact)
    }

    private var emptyState: some View {
        VStack(spacing: UIScale.pt(12)) {
            HostOnboardingIcon(symbolName: "checkmark.shield", size: 44, tint: DashSkin.ok)
            Text(
                filter == .attention
                    ? "Everything your tools need is allowed."
                    : "Turn on a tool to see the access it needs."
            )
            .font(.edithText(.callout))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if filter != .attention {
                Button("Browse Extensions") { openExtensions() }
                    .buttonStyle(.edith(.secondary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(40))
    }

    private func grant(_ usage: HostPermissionUsage) {
        Task { await permissions.request(usage.permission) }
    }
}

private struct HostPermissionCard: View {
    let usage: HostPermissionUsage
    var awaitingRelaunch = false
    let grant: (HostPermissionUsage) -> Void
    @Environment(\.colorScheme) private var scheme

    private var permission: HostPermission { usage.permission }

    var body: some View {
        let dark = scheme == .dark
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            HostOnboardingIcon(
                symbolName: permission.symbolName, size: 36,
                tint: usage.isGranted ? DashSkin.ok : nil)
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(alignment: .center, spacing: UIScale.pt(8)) {
                    Text(permission.displayName).font(.edithText(.headline)).lineLimit(1)
                    statusBadge
                    Spacer(minLength: 0)
                    action
                }
                .frame(minHeight: UIScale.pt(28))
                Text(permission.firstUseExplanation ?? permission.plainWords)
                    .font(.edithText(.callout)).foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                if !usage.users.isEmpty { usedByRow }
            }
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .hostOnboardingTile(warning: usage.blocksEnabledExtension)
    }

    @ViewBuilder private var statusBadge: some View {
        if usage.isGranted {
            HostOnboardingBadge("Allowed", DashSkin.ok)
        } else if awaitingRelaunch {
            HostOnboardingBadge("Relaunch to finish", DashSkin.warn)
        } else if usage.blocksEnabledExtension {
            HostOnboardingBadge("Needed now", DashSkin.warn)
        } else if usage.grantsOnFirstUse {
            HostOnboardingBadge("On first use", .secondary)
        }
    }

    @ViewBuilder private var action: some View {
        if !usage.isGranted && !permission.grantsOnFirstUse {
            Button("Allow") { grant(usage) }
                .buttonStyle(.edith(.secondary))
                .fixedSize()
                .accessibilityLabel("Allow \(permission.displayName)")
        }
    }

    private var usedByRow: some View {
        WrapHStack(spacing: UIScale.pt(6), lineSpacing: UIScale.pt(6)) {
            ForEach(usage.users) { entry in
                let enabled = usage.enabledUsers.contains(entry)
                let required = usage.requiredBy.contains(entry)
                HStack(spacing: UIScale.pt(4)) {
                    Image(systemName: entry.symbolName).imageScale(.small)
                    Text(entry.title)
                    if required { Text("required").foregroundStyle(.tertiary) }
                }
                .font(.edithText(.caption))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .padding(.horizontal, UIScale.pt(8))
                .frame(minHeight: UIScale.pt(20))
                .background(Color.primary.opacity(enabled ? 0.08 : 0.04), in: Capsule())
            }
        }
    }
}
