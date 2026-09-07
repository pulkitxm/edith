import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseConnectionOverview: View {
    let model: DatabaseConnectionWorkspaceModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.databaseAppTheme) private var appTheme

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        Group {
            if let connection = model.selectedConnection {
                VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                    connectionHeader(connection)
                    safetyCard(connection)
                    sessionCard(connection)
                    capabilitiesCard(connection)
                }
                .frame(maxWidth: UIScale.pt(760), alignment: .leading)
                .padding(UIScale.pt(28))
            } else {
                noSelection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionHeader(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
                Text(connection.name)
                    .font(.system(size: UIScale.pt(24), weight: .semibold))
                    .tracking(-0.4)
                    .lineLimit(2)
                if connection.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(DashSkin.gold)
                        .accessibilityLabel("Favorite connection")
                }
                Spacer(minLength: 0)
            }
            Text("\(connection.product.displayName) · \(connection.environmentLabel)")
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(palette.inkFaint)
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                        connectionBadges(connection)
                    }
                } else {
                    HStack(spacing: UIScale.pt(7)) {
                        connectionBadges(connection)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                connection.name,
                connection.product.displayName,
                connection.environmentSummary,
                connection.readOnlySummary,
                connection.isFavorite ? "Favorite" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
        )
    }

    @ViewBuilder
    private func connectionBadges(_ connection: DatabaseConnectionSummary) -> some View {
        badge(connection.environmentKind.title, tint: environmentColor(connection))
        badge(connection.environmentProtection.title, tint: protectionColor(connection))
        badge(connection.readOnlySummary, tint: readOnlyColor(connection))
    }

    private func safetyCard(_ connection: DatabaseConnectionSummary) -> some View {
        sectionCard(title: "Connection context", symbol: "shield.lefthalf.filled") {
            factRow("Environment", connection.environmentSummary)
            factRow("Access", connection.readOnlySummary)
            factRow("Mutation policy", connection.productionSummary)
            if let group = connection.group {
                factRow("Group", group)
            }
            if !connection.tags.isEmpty {
                factRow("Tags", connection.tags.joined(separator: ", "))
            }
        }
    }

    private func sessionCard(_ connection: DatabaseConnectionSummary) -> some View {
        sectionCard(title: "Session", symbol: "bolt.horizontal.circle") {
            switch model.selectedSessionState {
            case .disconnected:
                sessionStatus(
                    symbol: "circle",
                    title: "Disconnected",
                    detail: "Connecting is always an explicit action.",
                    tint: palette.inkFaint)
                Button("Connect") {
                    Task { await model.connectSelected() }
                }
                .buttonStyle(.edith(.primary, tint: palette.accent))
                .accessibilityLabel("Connect to \(connection.name)")
            case .connecting:
                SkeletonReplica("Connecting to \(connection.name)") {
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        sessionStatus(
                            symbol: "checkmark.circle.fill",
                            title: "Connected",
                            detail: "A secure database session is available.",
                            tint: DashSkin.ok)
                        Button("Disconnect") {}
                            .buttonStyle(.edith(.secondary))
                    }
                }
            case .connected(let session, let quality):
                sessionStatus(
                    symbol: "checkmark.circle.fill",
                    title: "Connected",
                    detail: connectedDetail(session),
                    tint: DashSkin.ok)
                qualityNotice(quality, noun: "connection information")
                Button("Disconnect") {
                    Task { await model.disconnectSelected() }
                }
                .buttonStyle(.edith(.secondary))
                .accessibilityLabel("Disconnect \(connection.name)")
            case .disconnecting:
                SkeletonReplica("Disconnecting from \(connection.name)") {
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        sessionStatus(
                            symbol: "circle",
                            title: "Disconnected",
                            detail: "Connecting is always an explicit action.",
                            tint: palette.inkFaint)
                        Button("Connect") {}
                            .buttonStyle(.edith(.primary, tint: palette.accent))
                    }
                }
            case .failed(let message, let previous):
                sessionStatus(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Session error",
                    detail: message,
                    tint: DashSkin.danger)
                if previous == nil {
                    Button("Try connecting again") {
                        Task { await model.connectSelected() }
                    }
                    .buttonStyle(.edith(.primary, tint: palette.accent))
                    .accessibilityLabel("Try connecting to \(connection.name) again")
                } else {
                    Button("Try disconnecting again") {
                        Task { await model.disconnectSelected() }
                    }
                    .buttonStyle(.edith(.secondary))
                    .accessibilityLabel("Try disconnecting \(connection.name) again")
                }
            case .outcomeUnknown(let message, let previous):
                sessionStatus(
                    symbol: "questionmark.circle.fill",
                    title: "Session status unknown",
                    detail: message,
                    tint: DashSkin.warn)
                if let previous {
                    Text(connectedDetail(previous))
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(palette.inkFaint)
                }
                Button("Disconnect to resolve status") {
                    Task { await model.disconnectSelected() }
                }
                .buttonStyle(.edith(.secondary))
                .accessibilityLabel("Disconnect \(connection.name) to resolve its status")
            }
        }
    }

    private func capabilitiesCard(_ connection: DatabaseConnectionSummary) -> some View {
        sectionCard(title: "Capabilities", symbol: "switch.2") {
            switch model.selectedCapabilityState {
            case .unavailable:
                Text("Connect to discover the features available for this database.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            case .refreshing(let snapshot, let quality):
                SkeletonReplica("Refreshing database capabilities") {
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        capabilityActions(connection)
                        if let snapshot {
                            capabilitySnapshot(snapshot, quality: quality ?? .partial)
                        } else {
                            capabilitySnapshotPlaceholder
                        }
                    }
                }
            case .loaded(let snapshot, let quality):
                capabilityActions(connection)
                qualityNotice(quality, noun: "capability information")
                capabilitySnapshot(snapshot, quality: quality)
            case .failed(let message, let snapshot, let quality):
                sessionStatus(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Capability refresh failed",
                    detail: message,
                    tint: DashSkin.danger)
                capabilityActions(connection)
                if let snapshot {
                    qualityNotice(quality ?? .stale, noun: "previous capability information")
                    capabilitySnapshot(snapshot, quality: quality ?? .stale)
                }
            }
        }
    }

    private var capabilitySnapshotPlaceholder: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(12)) {
                capabilityCount(12, label: "available", tint: DashSkin.ok)
                capabilityCount(2, label: "degraded", tint: DashSkin.warn)
                capabilityCount(4, label: "unavailable", tint: palette.inkFaint)
            }
            factRow("Product", "Database product and version")
            factRow("Topology", "Primary and replica topology")
            factRow("Source", "Live database session")
            factRow("Discovered", "Today at 10:30 AM")
            Divider().opacity(0.35)
            VStack(spacing: UIScale.pt(7)) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(alignment: .top, spacing: UIScale.pt(8)) {
                        Image(systemName: "checkmark.circle.fill")
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(index.isMultiple(of: 2) ? "Browse records" : "Run read queries")
                                .font(DashSkin.mono(10.5, weight: .medium))
                            Text("Available")
                                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIScale.pt(8))
                    .background(
                        palette.canvas,
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                }
            }
        }
    }

    private func capabilityActions(_ connection: DatabaseConnectionSummary) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                Task { await model.refreshSelectedCapabilities() }
            } label: {
                Label("Refresh capabilities", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.edith(.secondary))
            .accessibilityLabel("Refresh capabilities for \(connection.name)")
        }
    }

    private func capabilitySnapshot(
        _ snapshot: DatabaseCapabilitySnapshot,
        quality: DatabaseConnectionDataQuality
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(12)) {
                capabilityCount(snapshot.availableCount, label: "available", tint: DashSkin.ok)
                capabilityCount(snapshot.degradedCount, label: "degraded", tint: DashSkin.warn)
                capabilityCount(
                    snapshot.unavailableCount,
                    label: "unavailable",
                    tint: palette.inkFaint)
            }
            factRow("Product", productDetail(snapshot))
            factRow("Topology", snapshot.topology.title)
            factRow("Source", snapshot.source.title)
            factRow(
                "Discovered",
                snapshot.discoveredAt.formatted(date: .abbreviated, time: .shortened))
            if let expiresAt = snapshot.expiresAt {
                factRow(
                    "Expires",
                    expiresAt.formatted(date: .abbreviated, time: .shortened))
            }
            Divider().opacity(0.35)
            VStack(spacing: UIScale.pt(7)) {
                ForEach(snapshot.capabilities) { capability in
                    capabilityRow(capability)
                }
            }
            if !snapshot.safetyLimitations.isEmpty {
                Divider().opacity(0.35)
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    Text("Safety limitations")
                        .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    ForEach(
                        Array(snapshot.safetyLimitations.enumerated()), id: \.offset
                    ) { _, value in
                        Label(value, systemImage: "exclamationmark.shield")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.warn)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Safety limitations")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(quality.title) database capabilities")
    }

    private func capabilityRow(_ capability: DatabaseCapabilitySummary) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(8)) {
            Image(systemName: capabilitySymbol(capability.availability))
                .foregroundStyle(capabilityColor(capability.availability))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(capability.name)
                    .font(DashSkin.mono(10.5, weight: .medium))
                Text(capability.availabilityTitle)
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(capabilityColor(capability.availability))
                if let reason = capability.unavailableReason {
                    Text(reason)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(8))
        .background(palette.canvas, in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [capability.name, capability.availabilityTitle, capability.unavailableReason]
                .compactMap { $0 }
                .joined(separator: ", "))
    }

    private func capabilityCount(_ count: Int, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(count.formatted())
                .font(.system(size: UIScale.pt(18), weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(palette.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) capabilities \(label)")
    }

    private func qualityNotice(
        _ quality: DatabaseConnectionDataQuality,
        noun: String
    ) -> some View {
        Group {
            switch quality {
            case .complete:
                EmptyView()
            case .partial:
                sessionStatus(
                    symbol: "exclamationmark.circle.fill",
                    title: "Partial \(noun)",
                    detail: "Some details were unavailable and are labeled conservatively.",
                    tint: DashSkin.warn)
            case .stale:
                sessionStatus(
                    symbol: "clock.arrow.circlepath",
                    title: "Stale \(noun)",
                    detail: "Refresh before relying on this information.",
                    tint: DashSkin.warn)
            }
        }
    }

    private func sessionStatus(
        symbol: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(9)) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(title)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                Text(detail)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
            Text(label)
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(palette.inkFaint)
                .frame(width: UIScale.pt(112), alignment: .leading)
            Text(value)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(palette.ink)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private func sectionCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Label(title, systemImage: symbol)
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(palette.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(16))
        .background(palette.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .stroke(palette.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(10.5), weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(4))
            .background(tint.opacity(0.1), in: Capsule())
    }

    private var noSelection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: UIScale.pt(32), weight: .light))
                .foregroundStyle(palette.inkFaint)
                .accessibilityHidden(true)
            Text("Select a saved connection")
                .font(.system(size: UIScale.pt(22), weight: .semibold))
            Text(
                "Review its environment and safety policy before opening a session."
            )
            .font(.system(size: UIScale.pt(13)))
            .foregroundStyle(palette.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: UIScale.pt(560), alignment: .leading)
        .padding(UIScale.pt(28))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Select a saved connection. "
                + "Review its environment and safety policy before connecting."
        )
    }

    private func environmentColor(_ connection: DatabaseConnectionSummary) -> Color {
        connection.environmentKind == .production ? DashSkin.warn : palette.accent
    }

    private func protectionColor(_ connection: DatabaseConnectionSummary) -> Color {
        connection.environmentProtection == .standard ? palette.inkFaint : DashSkin.warn
    }

    private func readOnlyColor(_ connection: DatabaseConnectionSummary) -> Color {
        connection.readOnlyPolicy == .disabled ? palette.inkFaint : DashSkin.ok
    }

    private func connectedDetail(_ session: DatabaseConnectedSessionSummary) -> String {
        let version = session.version.map { " \($0)" } ?? ""
        return
            "\(session.product.displayName)\(version), \(session.topology.title), connected \(session.connectedAt.formatted(date: .abbreviated, time: .shortened))."
    }

    private func productDetail(_ snapshot: DatabaseCapabilitySnapshot) -> String {
        snapshot.version.map { "\(snapshot.product.displayName) \($0)" }
            ?? snapshot.product.displayName
    }

    private func capabilitySymbol(_ availability: DatabaseCapabilityAvailability) -> String {
        switch availability {
        case .available: "checkmark.circle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .unavailable: "xmark.circle.fill"
        case .planned: "clock.fill"
        }
    }

    private func capabilityColor(_ availability: DatabaseCapabilityAvailability) -> Color {
        switch availability {
        case .available: DashSkin.ok
        case .degraded: DashSkin.warn
        case .unavailable, .planned: palette.inkFaint
        }
    }
}
