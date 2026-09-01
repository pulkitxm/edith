import AppKit
import EdithDatabase
import EdithKit
import SwiftUI

enum DatabaseConnectionCardAction: Hashable {
    case favorite
    case rename
    case edit
    case duplicate
    case delete
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
    @FocusState private var focusedConnectionID: DatabaseConnectionID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.databaseAppTheme) private var appTheme

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }
    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: UIScale.pt(compact ? 220 : 270),
                    maximum: UIScale.pt(360)),
                spacing: UIScale.pt(14),
                alignment: .top)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            catalogHeader
            Divider().opacity(0.35)
            ScrollView {
                content
                    .padding(.horizontal, UIScale.pt(compact ? 16 : 28))
                    .padding(.vertical, UIScale.pt(compact ? 18 : 24))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved database connections")
    }

    private var catalogHeader: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                Text("Connections")
                    .font(.system(size: UIScale.pt(compact ? 17 : 20), weight: .semibold))
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 0)
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
            EdithTextField(
                placeholder: "Search saved connections",
                text: $model.searchText,
                icon: "magnifyingglass",
                compact: true,
                clearable: true,
                onSubmit: reload
            )
            .frame(maxWidth: UIScale.pt(560))
            .accessibilityLabel("Search saved database connections")
        }
        .padding(.horizontal, UIScale.pt(compact ? 16 : 28))
        .padding(.vertical, UIScale.pt(compact ? 14 : 18))
        .background(palette.panel.opacity(0.64))
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter saved connections")
        .accessibilityLabel("Filter saved database connections")
    }

    @ViewBuilder
    private var content: some View {
        switch model.listState {
        case .idle:
            emptyState(
                symbol: "cylinder.split.1x2",
                title: "Connections not loaded",
                detail: "Load your saved database connections to get started.",
                actionTitle: "Load connections",
                action: reload)
        case .loading(let connections):
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                stateNotice(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Loading connections",
                    detail: "Saved connection information is being refreshed.",
                    tint: palette.accent,
                    progress: true)
                connectionCards(connections)
            }
        case .empty:
            emptyState(
                symbol: "cylinder.split.1x2",
                title: "Connect your first database",
                detail:
                    "Add a saved connection to browse tables, inspect records, and edit supported data.",
                actionTitle: "Add connection",
                action: createConnection)
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
            connectionCards(connections)
        case .partial(let connections):
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                stateNotice(
                    symbol: "exclamationmark.circle.fill",
                    title: "Partial connection list",
                    detail: "Some saved connections could not be loaded.",
                    tint: DashSkin.warn)
                connectionCards(connections)
            }
        case .stale(let connections):
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                stateNotice(
                    symbol: "clock.arrow.circlepath",
                    title: "Stale connection list",
                    detail: "The saved connection information may be out of date.",
                    tint: DashSkin.warn)
                connectionCards(connections)
            }
        case .failed(let connections, let message):
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                stateNotice(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Connections unavailable",
                    detail: message,
                    tint: DashSkin.danger,
                    retry: true)
                connectionCards(connections)
            }
        }
    }

    @ViewBuilder
    private func connectionCards(_ connections: [DatabaseConnectionSummary]) -> some View {
        if connections.isEmpty {
            Text("No connection entries are available in this result.")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("No connection entries are available in this result")
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(14)) {
                ForEach(connections) { connection in
                    connectionCard(connection)
                }
            }
        }
    }

    private func connectionCard(_ connection: DatabaseConnectionSummary) -> some View {
        let session = model.sessionState(for: connection.id)
        let hovered = hoveredConnectionID == connection.id
        let focused = focusedConnectionID == connection.id
        let highlighted = hovered || focused
        let accent = connectionAccent(connection)
        return ZStack(alignment: .topTrailing) {
            Button {
                openConnection(connection)
            } label: {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    HStack(alignment: .top, spacing: UIScale.pt(11)) {
                        ZStack {
                            RoundedRectangle(cornerRadius: UIScale.pt(9))
                                .fill(accent.opacity(highlighted ? 0.15 : 0.11))
                            Image(systemName: connection.product.gallerySymbolName)
                                .font(.system(size: UIScale.pt(16), weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .frame(width: UIScale.pt(38), height: UIScale.pt(38))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            HStack(spacing: UIScale.pt(6)) {
                                Text(connection.name)
                                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                                    .foregroundStyle(palette.ink)
                                    .lineLimit(2)
                                if connection.isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: UIScale.pt(9)))
                                        .foregroundStyle(DashSkin.gold)
                                        .accessibilityHidden(true)
                                }
                            }
                            Text(connectionSubtitle(connection))
                                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                                .foregroundStyle(palette.inkSoft)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Color.clear
                            .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: UIScale.pt(7)) {
                        Image(systemName: namespaceSymbol(connection))
                            .font(.system(size: UIScale.pt(9.5), weight: .medium))
                            .foregroundStyle(palette.inkFaint)
                            .accessibilityHidden(true)
                        Text(namespaceTitle(connection))
                            .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                            .foregroundStyle(palette.inkSoft)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if session != .disconnected {
                            Image(systemName: sessionSymbol(session))
                                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                                .foregroundStyle(sessionColor(session))
                                .accessibilityHidden(true)
                            Text(sessionTitle(session))
                                .font(.system(size: UIScale.pt(10), weight: .semibold))
                                .foregroundStyle(palette.inkSoft)
                        }
                    }
                }
                .padding(UIScale.pt(14))
                .frame(maxWidth: .infinity, minHeight: UIScale.pt(126), alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: UIScale.pt(13))
                        .fill(palette.panel.opacity(highlighted ? 0.86 : 0.74))
                        .overlay {
                            if highlighted {
                                RoundedRectangle(cornerRadius: UIScale.pt(13))
                                    .fill(accent.opacity(dark ? 0.045 : 0.035))
                            }
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(13)))
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

            if performConnectionAction != nil {
                connectionActionMenu(connection)
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

    private func connectionActionMenu(_ connection: DatabaseConnectionSummary) -> some View {
        Menu {
            connectionActions(connection)
        } label: {
            Image(systemName: busyConnectionID == connection.id ? "ellipsis" : "ellipsis.circle")
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(palette.inkSoft)
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                .background(palette.panel.opacity(0.94), in: Circle())
                .overlay(Circle().stroke(palette.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(UIScale.pt(10))
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
        progress: Bool = false,
        retry: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            if progress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(title)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .font(.system(size: UIScale.pt(11)))
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
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: UIScale.pt(14)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(14))
                    .fill(palette.accent.opacity(0.1))
                Image(systemName: symbol)
                    .font(.system(size: UIScale.pt(28), weight: .light))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: UIScale.pt(60), height: UIScale.pt(60))
            .accessibilityHidden(true)
            VStack(spacing: UIScale.pt(6)) {
                Text(title)
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(palette.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(actionTitle, action: action)
                .buttonStyle(.edith(.primary, tint: palette.accent))
        }
        .frame(maxWidth: UIScale.pt(480))
        .padding(.vertical, UIScale.pt(56))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
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
        Group {
            if compact {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    navigationRow
                    identityRow
                }
            } else {
                HStack(spacing: UIScale.pt(16)) {
                    navigationButton
                    Divider().frame(height: UIScale.pt(32))
                    identityRow
                    Spacer(minLength: 0)
                    if performConnectionAction != nil {
                        connectionActionMenu
                    }
                    sessionLabel
                }
            }
        }
        .padding(.horizontal, UIScale.pt(compact ? 12 : 18))
        .padding(.vertical, UIScale.pt(compact ? 10 : 12))
        .background(palette.panel.opacity(0.78))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Database workspace for \(connection.name)")
    }

    private var navigationRow: some View {
        HStack(spacing: UIScale.pt(10)) {
            navigationButton
            Spacer(minLength: 0)
            if performConnectionAction != nil {
                connectionActionMenu
            }
            sessionLabel
        }
    }

    private var navigationButton: some View {
        Button(action: back) {
            Label("All connections", systemImage: "chevron.left")
                .font(.system(size: UIScale.pt(11), weight: .medium))
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
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: UIScale.pt(34), height: UIScale.pt(34))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                HStack(spacing: UIScale.pt(7)) {
                    Text(connection.name)
                        .font(.system(size: UIScale.pt(13.5), weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    if connection.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: UIScale.pt(8.5)))
                            .foregroundStyle(DashSkin.gold)
                            .accessibilityLabel("Favorite connection")
                    }
                }
                Text(contextTitle)
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
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
                .font(.system(size: UIScale.pt(14), weight: .semibold))
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

    private var sessionLabel: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: sessionSymbol)
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .foregroundStyle(sessionColor)
                .accessibilityHidden(true)
            Text(sessionTitle)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(palette.inkSoft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sessionTitle)
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
