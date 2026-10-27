import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostControlLayout: Layout {
    var minimumWidth: Double
    var cellHeight: Double
    var gap: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? UIScale.pt(400)
        let rows = SurfaceArrangement.rowCounts(
            count: subviews.count, width: Double(width / UIScale.current),
            minimumWidth: minimumWidth, maximumColumns: subviews.count, gap: gap)
        let height = UIScale.pt(
            Double(rows.count) * cellHeight + Double(max(0, rows.count - 1)) * gap)
        return CGSize(
            width: width, height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = SurfaceArrangement.rowCounts(
            count: subviews.count, width: Double(bounds.width / UIScale.current),
            minimumWidth: minimumWidth, maximumColumns: subviews.count, gap: gap)
        guard !rows.isEmpty else { return }
        let gap = UIScale.pt(gap)
        let height = max(1, (bounds.height - CGFloat(rows.count - 1) * gap) / CGFloat(rows.count))
        var index = 0
        for (row, count) in rows.enumerated() {
            let width = max(1, (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
            for column in 0..<count {
                subviews[index].place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(column) * (width + gap),
                        y: bounds.minY + CGFloat(row) * (height + gap)), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height))
                index += 1
            }
        }
    }
}

extension HostSidebarUtility {
    var cardTitle: String { self == .presenter ? "Presenter mode" : title }
    var cardIcon: String {
        switch self {
        case .system: "keyboard"
        case .keepAwake: "moon.zzz"
        case .lidAwake: "laptopcomputer"
        case .keystrokeHighlight: "keyboard.badge.ellipsis"
        case .presenter: "person.wave.2"
        }
    }
    var cardSubtitle: String {
        switch self {
        case .system: "Lock the keyboard to wipe it"
        case .keepAwake: "Stop this Mac from sleeping"
        case .lidAwake: "Keep running with the lid closed"
        case .keystrokeHighlight: "Show keyboard input on screen"
        case .presenter: "Blur sensitive values on screen"
        }
    }
}

struct HostQuickActionsCard: View {
    let marketplace: HostMarketplace
    let tile: SurfaceTile
    var fill = false
    var openExtensions: (() -> Void)? = nil
    @State private var actions = HostUtilityActions()
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @Environment(\.windowVisible) private var visible

    private var theme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var active: Set<String> { marketplace.surfaceAvailability.activeIDs }
    private var versions: [String: String] {
        marketplace.sessions.versions.filter {
            active.contains($0.key) && HostSidebarUtility(rawValue: $0.key) != nil
        }
    }
    private var utilities: [HostSidebarUtility] {
        HostSidebarUtility.allCases.filter {
            versions[$0.id] != nil && tile.widget.providerIDs.contains($0.id)
        }
    }

    var body: some View {
        PageCard(title: tile.showTitle ? "Quick actions" : nil, fill: fill) {
            if utilities.isEmpty {
                Text("Enable desk and system controls in Extensions.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                if tile.showActions, let openExtensions {
                    Button("Choose controls", action: openExtensions)
                        .buttonStyle(.edith(.secondary))
                }
            }
            HostControlLayout(minimumWidth: 130, cellHeight: compact ? 72 : 112, gap: 12) {
                ForEach(utilities) { utility in control(utility) }
            }
            .frame(maxWidth: .infinity)
        }
        .pageTask(
            id: versions, active: visible && !versions.isEmpty, cancel: actions.clear
        ) {
            await actions.poll(
                utilities: utilities, marketplace: marketplace, tile: tile, versions: { versions })
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name("edith.lidAwakeChanged"))
        ) { _ in actions.refreshTick += 1 }
        .onDisappear(perform: actions.clear)
        .hostUtilityAlerts(actions, marketplace: marketplace, tile: tile) { id in versions[id] }
    }

    private func control(_ utility: HostSidebarUtility) -> some View {
        let on = actions.isOn(utility)
        return Button {
            guard visible, let version = versions[utility.id] else { return }
            actions.perform(
                utility, marketplace: marketplace, tile: tile, version: version,
                current: { versions[utility.id] })
        } label: {
            VStack(spacing: UIScale.pt(6)) {
                if tile.shows("icons") {
                    Image(
                        systemName: utility == .keepAwake && on ? "moon.zzz.fill" : utility.cardIcon
                    )
                    .font(.system(size: UIScale.pt(21)))
                    .frame(height: UIScale.pt(26))
                }
                Text(utility.cardTitle)
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !compact, tile.showDetails, tile.shows("descriptions") {
                    Text(utility.cardSubtitle)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(on ? .white.opacity(0.8) : DashSkin.inkFaint(dark))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, UIScale.pt(compact ? 8 : 16))
            .padding(.horizontal, UIScale.pt(8))
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(DashSkin.ink(dark)))
            .background(
                on ? AnyShapeStyle(theme) : AnyShapeStyle(.primary.opacity(0.05)),
                in: RoundedRectangle(cornerRadius: UIScale.pt(12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help(utility.cardSubtitle)
    }
}
