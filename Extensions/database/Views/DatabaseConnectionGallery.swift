import AppKit
import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

enum DatabaseConnectionCardAction: Hashable {
    case favorite
    case rename
    case edit
    case duplicate
    case delete
}

enum DatabaseConnectionRowMetrics {
    static let icon = 32.0
    static let horizontalPadding = 14.0
    static let verticalPadding = 10.0
    static let spacing = 12.0
    static let sessionWidth = 150.0
    static let menuSize = 28.0
    static var dividerInset: Double { horizontalPadding + icon + spacing }
}

struct DatabaseConnectionListSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius), style: .continuous))
    }
}

struct DatabaseConnectionRowDivider: View {
    var body: some View {
        Divider().padding(.leading, UIScale.pt(DatabaseConnectionRowMetrics.dividerInset))
    }
}

struct DatabaseConnectionRowSkeleton: View {
    let index: Int
    let accent: Color
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HStack(spacing: UIScale.pt(DatabaseConnectionRowMetrics.spacing)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(8)).fill(accent.opacity(0.11))
                Image(systemName: "cylinder")
                    .font(.edithText(.callout).weight(.semibold))
                    .foregroundStyle(accent)
            }
            .frame(
                width: UIScale.pt(DatabaseConnectionRowMetrics.icon),
                height: UIScale.pt(DatabaseConnectionRowMetrics.icon))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(index.isMultiple(of: 2) ? "Analytics warehouse" : "Primary database")
                    .font(.edithText(.body).weight(.semibold))
                    .lineLimit(1)
                Text(index.isMultiple(of: 2) ? "PostgreSQL · Production" : "MySQL")
                    .font(.edithText(.caption))
                    .lineLimit(1)
                if compact { namespace }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                namespace.frame(maxWidth: .infinity, alignment: .leading)
                Text("Ready to connect")
                    .font(.edithText(.caption))
                    .frame(
                        width: UIScale.pt(DatabaseConnectionRowMetrics.sessionWidth),
                        alignment: .trailing)
            }
            Image(systemName: "ellipsis.circle")
                .font(.edithText(.body).weight(.semibold))
                .frame(
                    width: UIScale.pt(DatabaseConnectionRowMetrics.menuSize),
                    height: UIScale.pt(DatabaseConnectionRowMetrics.menuSize))
        }
        .padding(.horizontal, UIScale.pt(DatabaseConnectionRowMetrics.horizontalPadding))
        .padding(.vertical, UIScale.pt(DatabaseConnectionRowMetrics.verticalPadding))
    }

    private var namespace: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "cylinder").font(.edithText(.caption).weight(.medium))
                .frame(width: UIScale.pt(16))
            Text(index.isMultiple(of: 2) ? "analytics" : "default_namespace")
                .font(.edithText(.caption)).lineLimit(1)
        }
    }
}

struct DatabaseConnectionGallery: View {
    @Bindable var model: DatabaseConnectionWorkspaceModel
    let createConnection: () -> Void
    let openConnection: (DatabaseConnectionSummary) -> Void
    var reloadConnections: (() -> Void)? = nil
    var restoreFocusConnectionID: DatabaseConnectionID? = nil
    var focusRestored: ((DatabaseConnectionID) -> Void)? = nil
    var busyConnectionID: DatabaseConnectionID? = nil
    var performConnectionAction:
        ((DatabaseConnectionCardAction, DatabaseConnectionSummary) -> Void)? = nil
    @State private var hoveredConnectionID: DatabaseConnectionID?
    @State private var scrollHeight: CGFloat = 0
    @FocusState private var focusedConnectionID: DatabaseConnectionID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.databaseAppTheme) private var appTheme

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            catalogHeader
            PageHeaderDivider()
            ScrollView {
                content
                    .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                    .pageContent(compact)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollHeight = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved database connections")
    }

    private var showsCatalogControls: Bool {
        if case .empty = model.listState { return false }
        return true
    }

    private var catalogHeader: some View {
        PageHeader(
            "Database",
            trailing: {
                if showsCatalogControls {
                    HStack(alignment: .center, spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                        Button(action: reload) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.edith(.secondary))
                        .help("Reload saved connections")
                        .accessibilityLabel("Reload saved database connections")
                        connectionFilterMenu
                        Button(action: createConnection) {
                            if compact {
                                Image(systemName: "plus")
                            } else {
                                Label("Add connection", systemImage: "plus")
                            }
                        }
                        .buttonStyle(.edith(.primary, tint: palette.accent))
                        .accessibilityLabel("Add a database connection")
                    }
                }
            },
            accessory: {
                if showsCatalogControls {
                    EdithTextField(
                        placeholder: "Search saved connections",
                        text: $model.searchText,
                        icon: "magnifyingglass",
                        compact: true,
                        clearable: true,
                        onSubmit: reload
                    )
                    .accessibilityLabel("Search saved database connections")
                }
            })
    }

    private var connectionFilterMenu: some View {
        Menu {
            Button {
                model.favoritesOnly.toggle()
            } label: {
                Label(
                    "Favorites only",
                    systemImage: model.favoritesOnly ? "checkmark" : "star")
            }
            if !model.availableGroups.isEmpty {
                Divider()
                Button {
                    model.selectedGroup = nil
                } label: {
                    if model.selectedGroup == nil {
                        Label("All groups", systemImage: "checkmark")
                    } else {
                        Text("All groups")
                    }
                }
                ForEach(model.availableGroups) { group in
                    Button {
                        model.selectedGroup = group.id
                    } label: {
                        Label(
                            group.label,
                            systemImage: model.selectedGroup == group.id ? "checkmark" : "folder")
                    }
                }
            }
            if model.favoritesOnly || model.selectedGroup != nil {
                Divider()
                Button("Clear filters") {
                    model.clearFilters()
                }
            }
        } label: {
            Image(
                systemName: model.favoritesOnly || model.selectedGroup != nil
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.edith(.secondary))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter saved connections")
        .accessibilityLabel("Filter saved database connections")
    }

    @ViewBuilder
    private var content: some View {
        switch model.listState {
        case .idle:
            loadingConnectionRows([])
        case .loading(let connections):
            loadingConnectionRows(connections)
        case .empty:
            emptyState(
                symbol: "cylinder.split.1x2",
                title: "Connect your first database",
                detail:
                    "Save a connection once, then browse tables, search records and edit data with a preview before every change.",
                actionTitle: "Add connection",
                action: createConnection,
                steps: [
                    PageGuideStep(
                        symbolName: "server.rack", title: "Choose a database",
                        detail: "PostgreSQL, MySQL, SQLite, MongoDB, Redis and more."),
                    PageGuideStep(
                        symbolName: "key", title: "Enter its details",
                        detail:
                            "Host and login, or a file for SQLite. Passwords go to your Keychain."),
                    PageGuideStep(
                        symbolName: "checkmark.shield", title: "Edit with confidence",
                        detail: "Every change is previewed and needs your confirmation."),
                ],
                footnote: "Nothing connects until you open a saved connection.")
        case .filteredEmpty(let search):
            emptyState(
                symbol: "magnifyingglass",
                title: "No matching connections",
                detail: hasStructuredFilters
                    ? "No saved connection matches the current filters."
                    : "No saved connection matches \"\(search)\".",
                actionTitle: hasStructuredFilters ? "Clear filters" : "Clear search",
                action: clearFilters)
        case .loaded(let connections):
            connectionRows(connections)
        case .partial(let connections):
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                stateNotice(
                    symbol: "exclamationmark.circle.fill",
                    title: "Partial connection list",
                    detail: "Some saved connections could not be loaded.",
                    tint: DashSkin.warn)
                connectionRows(connections)
            }
        case .stale(let connections):
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                stateNotice(
                    symbol: "clock.arrow.circlepath",
                    title: "Stale connection list",
                    detail: "The saved connection information may be out of date.",
                    tint: DashSkin.warn)
                connectionRows(connections)
            }
        case .failed(let connections, let message):
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                stateNotice(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Connections unavailable",
                    detail: message,
                    tint: DashSkin.danger,
                    retry: true)
                connectionRows(connections)
            }
        }
    }

    private func loadingConnectionRows(_ connections: [DatabaseConnectionSummary]) -> some View {
        SkeletonReplica("Loading saved database connections") {
            Group {
                if connections.isEmpty {
                    DatabaseConnectionListSurface {
                        ForEach(0..<6, id: \.self) { index in
                            if index > 0 { DatabaseConnectionRowDivider() }
                            DatabaseConnectionRowSkeleton(index: index, accent: palette.accent)
                        }
                    }
                } else {
                    connectionRows(connections)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionRows(_ connections: [DatabaseConnectionSummary]) -> some View {
        if connections.isEmpty {
            Text("No connection entries are available in this result.")
                .font(.edithText(.callout))
                .foregroundStyle(palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("No connection entries are available in this result")
        } else {
            DatabaseConnectionListSurface {
                ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
                    if index > 0 { DatabaseConnectionRowDivider() }
                    connectionRow(connection)
                }
            }
        }
    }

    private func connectionRow(_ connection: DatabaseConnectionSummary) -> some View {
        let session = model.sessionState(for: connection.id)
        let hovered = hoveredConnectionID == connection.id
        let focused = focusedConnectionID == connection.id
        let highlighted = hovered || focused
        let accent = connectionAccent(connection)
        return ZStack(alignment: .trailing) {
            Button {
                openConnection(connection)
            } label: {
                HStack(spacing: UIScale.pt(DatabaseConnectionRowMetrics.spacing)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: UIScale.pt(8))
                            .fill(accent.opacity(highlighted ? 0.15 : 0.11))
                        Image(systemName: connection.product.gallerySymbolName)
                            .font(.edithText(.callout).weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    .frame(
                        width: UIScale.pt(DatabaseConnectionRowMetrics.icon),
                        height: UIScale.pt(DatabaseConnectionRowMetrics.icon)
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text(connection.name)
                                .font(.edithText(.body).weight(.semibold))
                                .foregroundStyle(palette.ink)
                                .lineLimit(1)
                            if connection.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.edithText(.caption))
                                    .foregroundStyle(DashSkin.gold)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(connectionSubtitle(connection))
                            .font(.edithText(.caption))
                            .foregroundStyle(palette.inkSoft)
                            .lineLimit(1)
                        if compact {
                            HStack(spacing: UIScale.pt(DatabaseConnectionRowMetrics.spacing)) {
                                namespaceLabel(connection)
                                HStack(spacing: UIScale.pt(6)) { connectionSessionSlot(session) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !compact {
                        namespaceLabel(connection)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: UIScale.pt(6)) { connectionSessionSlot(session) }
                            .frame(
                                width: UIScale.pt(DatabaseConnectionRowMetrics.sessionWidth),
                                alignment: .trailing)
                    }
                    Color.clear
                        .frame(
                            width: UIScale.pt(DatabaseConnectionRowMetrics.menuSize),
                            height: UIScale.pt(DatabaseConnectionRowMetrics.menuSize)
                        )
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, UIScale.pt(DatabaseConnectionRowMetrics.horizontalPadding))
                .padding(.vertical, UIScale.pt(DatabaseConnectionRowMetrics.verticalPadding))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlighted ? accent.opacity(dark ? 0.045 : 0.035) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .focused($focusedConnectionID, equals: connection.id)
            .focusEffectDisabled()
            .background {
                DatabaseKeyboardFocusAnchor(active: focusRequest.target == connection.id) {
                    guard focusRequest.target == connection.id else { return }
                    focusRestored?(connection.id)
                }
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                [
                    connection.name,
                    connection.product.displayName,
                    connection.environmentSummary,
                    connection.readOnlySummary,
                    connection.isFavorite ? "Favorite" : nil,
                    sessionTitle(session),
                ].compactMap { $0 }.joined(separator: ", ")
            )
            .accessibilityHint("Open this database workspace")
            .accessibilityAction { openConnection(connection) }

            if performConnectionAction != nil {
                if busyConnectionID == connection.id {
                    loadingConnectionAction(connection)
                } else {
                    connectionActionMenu(connection)
                }
            }
        }
        .onHover { isHovered in hoveredConnectionID = isHovered ? connection.id : nil }
        .animation(nil, value: highlighted)
        .contextMenu {
            if performConnectionAction != nil {
                connectionActions(connection)
            }
        }
    }

    private func namespaceLabel(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: namespaceSymbol(connection))
                .font(.edithText(.caption).weight(.medium))
                .foregroundStyle(palette.inkFaint)
                .frame(width: UIScale.pt(16))
                .accessibilityHidden(true)
            Text(namespaceTitle(connection))
                .font(.edithText(.caption))
                .foregroundStyle(palette.inkSoft)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func connectionSessionSlot(_ session: DatabaseConnectionSessionState) -> some View {
        switch session {
        case .disconnected:
            Text(sessionTitle(session))
                .font(.edithText(.caption))
                .foregroundStyle(palette.inkSoft)
        case .connecting, .disconnecting:
            SkeletonReplica(sessionTitle(session)) {
                HStack(spacing: UIScale.pt(7)) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.edithText(.caption).weight(.semibold))
                    Text("Connected")
                        .font(.edithText(.caption).weight(.semibold))
                }
            }
        case .connected, .failed, .outcomeUnknown:
            Image(systemName: sessionSymbol(session))
                .font(.edithText(.caption).weight(.semibold))
                .foregroundStyle(sessionColor(session))
                .accessibilityHidden(true)
            Text(sessionTitle(session))
                .font(.edithText(.caption).weight(.semibold))
                .foregroundStyle(palette.inkSoft)
        }
    }

    private func loadingConnectionAction(_ connection: DatabaseConnectionSummary) -> some View {
        SkeletonReplica("Updating \(connection.name)") {
            Image(systemName: "ellipsis.circle")
                .font(.edithText(.body).weight(.semibold))
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                .background(palette.panel.opacity(0.94), in: Circle())
                .overlay(Circle().stroke(palette.line, lineWidth: 1))
        }
        .padding(.trailing, UIScale.pt(DatabaseConnectionRowMetrics.horizontalPadding))
    }

    private func connectionActionMenu(_ connection: DatabaseConnectionSummary) -> some View {
        Menu {
            connectionActions(connection)
        } label: {
            Image(systemName: busyConnectionID == connection.id ? "ellipsis" : "ellipsis.circle")
                .font(.edithText(.body).weight(.semibold))
                .foregroundStyle(palette.inkSoft)
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                .background(palette.panel.opacity(0.94), in: Circle())
                .overlay(Circle().stroke(palette.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, UIScale.pt(DatabaseConnectionRowMetrics.horizontalPadding))
        .disabled(busyConnectionID != nil)
        .help("Manage \(connection.name)")
        .accessibilityLabel("Actions for \(connection.name)")
    }

    @ViewBuilder
    private func connectionActions(_ connection: DatabaseConnectionSummary) -> some View {
        Button {
            openConnection(connection)
        } label: {
            Label("Open", systemImage: "arrow.up.right.square")
        }
        Button {
            performConnectionAction?(.favorite, connection)
        } label: {
            Label(
                connection.isFavorite ? "Remove from favorites" : "Add to favorites",
                systemImage: connection.isFavorite ? "star.slash" : "star")
        }
        Divider()
        Button {
            performConnectionAction?(.rename, connection)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            performConnectionAction?(.edit, connection)
        } label: {
            Label("Edit metadata and safety", systemImage: "slider.horizontal.3")
        }
        Button {
            performConnectionAction?(.duplicate, connection)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) {
            performConnectionAction?(.delete, connection)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func stateNotice(
        symbol: String,
        title: String,
        detail: String,
        tint: Color,
        retry: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(title)
                    .font(.edithText(.callout).weight(.semibold))
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .font(.edithText(.subheadline))
                    .foregroundStyle(palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if retry {
                Button("Try again", action: reload)
                    .buttonStyle(.edith(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(12))
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func emptyState(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void,
        steps: [PageGuideStep] = [],
        footnote: String? = nil
    ) -> some View {
        PageEmptyState(
            symbolName: symbol,
            title: title,
            message: detail,
            steps: steps,
            primary: PageAction(
                actionTitle, symbolName: steps.isEmpty ? nil : "plus", perform: action),
            footnote: footnote
        )
        .frame(minHeight: emptyStateHeight)
    }

    private var emptyStateHeight: CGFloat {
        max(
            UIScale.pt(320),
            scrollHeight - UIScale.pt(PageMetrics.pinnedContentTop + PageMetrics.bottom))
    }

    private func reload() {
        if let reloadConnections {
            reloadConnections()
        } else {
            Task { await model.loadConnections() }
        }
    }

    private func clearFilters() {
        model.clearFilters()
    }

    private var hasStructuredFilters: Bool {
        model.favoritesOnly || model.selectedGroup != nil
    }

    private func connectionAccent(_ connection: DatabaseConnectionSummary) -> Color {
        guard let color = connection.color, let theme = AppTheme(rawValue: color) else {
            return palette.accent
        }
        return DashSkin.accent(dark, theme: theme)
    }

    private var focusRequest: DatabaseConnectionGalleryFocusRequest {
        DatabaseConnectionGalleryFocusRequest(
            requestedConnectionID: restoreFocusConnectionID,
            visibleConnectionIDs: model.visibleConnections.map(\.id))
    }

    private func connectionSubtitle(_ connection: DatabaseConnectionSummary) -> String {
        if connection.environmentKind == .development {
            return connection.product.displayName
        }
        return "\(connection.product.displayName) · \(connection.environmentKind.title)"
    }

    private func namespaceTitle(_ connection: DatabaseConnectionSummary) -> String {
        connection.defaultDatabase ?? connection.logicalDatabase ?? connection.defaultSchema
            ?? "Default namespace"
    }

    private func namespaceSymbol(_ connection: DatabaseConnectionSummary) -> String {
        connection.product.family == .relational ? "cylinder" : "square.stack.3d.up"
    }

    private func sessionTitle(_ state: DatabaseConnectionSessionState) -> String {
        switch state {
        case .disconnected: "Ready to connect"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Connection issue"
        case .outcomeUnknown: "Status unknown"
        }
    }

    private func sessionSymbol(_ state: DatabaseConnectionSessionState) -> String {
        switch state {
        case .disconnected: "circle"
        case .connecting, .disconnecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .outcomeUnknown: "questionmark.circle.fill"
        }
    }

    private func sessionColor(_ state: DatabaseConnectionSessionState) -> Color {
        switch state {
        case .disconnected: palette.inkFaint
        case .connecting, .disconnecting: palette.accent
        case .connected: DashSkin.ok
        case .failed: DashSkin.danger
        case .outcomeUnknown: DashSkin.warn
        }
    }
}

struct DatabaseFocusedConnectionHeader: View {
    let connection: DatabaseConnectionSummary
    let sessionState: DatabaseConnectionSessionState
    let backDisabled: Bool
    let focusRequested: Bool
    let focusCompleted: () -> Void
    let back: () -> Void
    var busyConnectionID: DatabaseConnectionID? = nil
    var performConnectionAction:
        ((DatabaseConnectionCardAction, DatabaseConnectionSummary) -> Void)? = nil
    @FocusState private var backFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.databaseAppTheme) private var appTheme

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        PageHeader {
            identityRow
        } trailing: {
            navigationRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Database workspace for \(connection.name)")
    }

    private var navigationRow: some View {
        HStack(spacing: UIScale.pt(10)) {
            navigationButton
            if performConnectionAction != nil {
                connectionActionSlot
            }
            sessionLabel
        }
    }

    @ViewBuilder
    private var connectionActionSlot: some View {
        if busyConnectionID == connection.id {
            SkeletonReplica("Updating \(connection.name)") {
                Image(systemName: "ellipsis.circle")
                    .font(.edithText(.title3).weight(.semibold))
                    .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            }
        } else {
            connectionActionMenu
        }
    }

    private var navigationButton: some View {
        Button(action: back) {
            Label("All connections", systemImage: "chevron.left")
                .font(.edithText(.subheadline).weight(.medium))
                .foregroundStyle(backFocused ? palette.ink : palette.inkSoft)
                .padding(.horizontal, UIScale.pt(8))
                .frame(minHeight: UIScale.pt(28))
                .background(
                    palette.ink.opacity(backFocused ? (dark ? 0.1 : 0.06) : 0),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                )
                .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
        }
        .buttonStyle(.edith(.borderless))
        .focused($backFocused)
        .focusEffectDisabled()
        .background {
            DatabaseKeyboardFocusAnchor(
                active: focusRequested && !backDisabled,
                focusCompleted: focusCompleted
            )
            .accessibilityHidden(true)
        }
        .disabled(backDisabled)
        .help(
            backDisabled
                ? "Resolve the active database change before leaving this workspace"
                : "Return to all saved connections"
        )
        .accessibilityHint(
            backDisabled
                ? "Resolve the active database change before returning"
                : "Return to the saved connection cards"
        )
    }

    private var identityRow: some View {
        let accent = connectionAccent
        return HStack(spacing: UIScale.pt(10)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .fill(accent.opacity(0.11))
                Image(systemName: connection.product.gallerySymbolName)
                    .font(.edithText(.title3).weight(.semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: UIScale.pt(34), height: UIScale.pt(34))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                HStack(spacing: UIScale.pt(7)) {
                    Text(connection.name)
                        .font(.edithText(.title2).weight(.semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                    if connection.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: UIScale.pt(8.5)))
                            .foregroundStyle(DashSkin.gold)
                            .accessibilityLabel("Favorite connection")
                    }
                }
                Text(contextTitle)
                    .font(.edithText(.caption).weight(.medium))
                    .foregroundStyle(palette.inkSoft)
                    .lineLimit(compact ? 2 : 1)
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
            ].compactMap { $0 }.joined(separator: ", "))
    }

    private var connectionActionMenu: some View {
        Menu {
            Button {
                performConnectionAction?(.favorite, connection)
            } label: {
                Label(
                    connection.isFavorite ? "Remove from favorites" : "Add to favorites",
                    systemImage: connection.isFavorite ? "star.slash" : "star")
            }
            Divider()
            Button {
                performConnectionAction?(.rename, connection)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                performConnectionAction?(.edit, connection)
            } label: {
                Label("Edit metadata and safety", systemImage: "slider.horizontal.3")
            }
            Button {
                performConnectionAction?(.duplicate, connection)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                performConnectionAction?(.delete, connection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.edithText(.title3).weight(.semibold))
                .foregroundStyle(palette.inkSoft)
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busyConnectionID != nil)
        .help("Manage \(connection.name)")
        .accessibilityLabel("Actions for \(connection.name)")
    }

    private var connectionAccent: Color {
        guard let color = connection.color, let theme = AppTheme(rawValue: color) else {
            return palette.accent
        }
        return DashSkin.accent(dark, theme: theme)
    }

    @ViewBuilder
    private var sessionLabel: some View {
        if sessionIsTransitioning {
            SkeletonReplica(sessionTitle) {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.edithText(.caption).weight(.semibold))
                    Text("Connected")
                        .font(.edithText(.caption).weight(.semibold))
                }
            }
        } else {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: sessionSymbol)
                    .font(.edithText(.caption).weight(.semibold))
                    .foregroundStyle(sessionColor)
                    .accessibilityHidden(true)
                Text(sessionTitle)
                    .font(.edithText(.caption).weight(.semibold))
                    .foregroundStyle(palette.inkSoft)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(sessionTitle)
        }
    }

    private var sessionIsTransitioning: Bool {
        switch sessionState {
        case .connecting, .disconnecting: true
        case .disconnected, .connected, .failed, .outcomeUnknown: false
        }
    }

    private var contextTitle: String {
        let namespace =
            connection.defaultDatabase ?? connection.logicalDatabase ?? connection.defaultSchema
        guard let namespace, !namespace.isEmpty else { return connection.product.displayName }
        return "\(connection.product.displayName) · \(namespace)"
    }

    private var sessionTitle: String {
        switch sessionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Connection issue"
        case .outcomeUnknown: "Status unknown"
        }
    }

    private var sessionSymbol: String {
        switch sessionState {
        case .disconnected: "circle"
        case .connecting, .disconnecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .outcomeUnknown: "questionmark.circle.fill"
        }
    }

    private var sessionColor: Color {
        switch sessionState {
        case .disconnected: palette.inkFaint
        case .connecting, .disconnecting: palette.accent
        case .connected: DashSkin.ok
        case .failed: DashSkin.danger
        case .outcomeUnknown: DashSkin.warn
        }
    }
}

private extension DatabaseProduct {
    var gallerySymbolName: String {
        switch family {
        case .relational: "tablecells"
        case .keyValue: "key.horizontal"
        case .document: "doc.text"
        case .search: "magnifyingglass.circle"
        case .analytical: "chart.xyaxis.line"
        }
    }
}

struct DatabaseConnectionGalleryFocusRequest: Hashable {
    let requestedConnectionID: DatabaseConnectionID?
    let visibleConnectionIDs: [DatabaseConnectionID]

    var target: DatabaseConnectionID? {
        guard let requestedConnectionID,
            visibleConnectionIDs.contains(requestedConnectionID)
        else { return nil }
        return requestedConnectionID
    }
}

private struct DatabaseKeyboardFocusAnchor: NSViewRepresentable {
    let active: Bool
    let focusCompleted: () -> Void

    func makeNSView(context: Context) -> DatabaseKeyboardFocusAnchorView {
        let view = DatabaseKeyboardFocusAnchorView()
        view.focusCompleted = focusCompleted
        view.active = active
        return view
    }

    func updateNSView(_ nsView: DatabaseKeyboardFocusAnchorView, context: Context) {
        nsView.focusCompleted = focusCompleted
        nsView.active = active
        nsView.requestFocus()
    }
}

@MainActor
private final class DatabaseKeyboardFocusAnchorView: NSView {
    var focusCompleted: (() -> Void)?
    var active = false {
        didSet {
            guard active != oldValue else { return }
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(runFocusRequest),
                object: nil)
            attempts = 0
            requestScheduled = false
            didFocus = false
            requestFocus()
        }
    }

    private var attempts = 0
    private var requestScheduled = false
    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(runFocusRequest),
                object: nil)
            requestScheduled = false
            return
        }
        attempts = 0
        requestFocus()
    }

    override func layout() {
        super.layout()
        requestFocus()
    }

    func requestFocus() {
        guard active, !didFocus, attempts < 8 else { return }
        if let window, let candidate = focusCandidate(in: window) {
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(runFocusRequest),
                object: nil)
            requestScheduled = false
            didFocus = window.firstResponder === candidate || window.makeFirstResponder(candidate)
            if didFocus {
                NSAccessibility.post(element: candidate, notification: .focusedUIElementChanged)
                let focusCompleted = focusCompleted
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(10))
                    focusCompleted?()
                }
                return
            }
        }
        guard !requestScheduled else { return }
        requestScheduled = true
        perform(#selector(runFocusRequest), with: nil, afterDelay: 0.01)
    }

    @objc private func runFocusRequest() {
        requestScheduled = false
        guard active, !didFocus else { return }
        attempts += 1
        requestFocus()
    }

    private func focusCandidate(in window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        window.recalculateKeyViewLoop()
        let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: contentView)
        let candidates = descendants(of: contentView)
            .filter { view in
                guard view !== self, !view.isHidden, !isDescendant(of: view),
                    view.nextKeyView != nil || view.previousKeyView != nil
                else {
                    return false
                }
                return view.convert(view.bounds, to: contentView).contains(center)
            }

        return
            candidates
            .min { first, second in
                let firstFrame = first.convert(first.bounds, to: contentView)
                let secondFrame = second.convert(second.bounds, to: contentView)
                return firstFrame.width * firstFrame.height < secondFrame.width * secondFrame.height
            }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
