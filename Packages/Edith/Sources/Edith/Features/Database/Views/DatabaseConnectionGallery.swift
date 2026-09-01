import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseConnectionGallery: View {
    @Bindable var model: DatabaseConnectionWorkspaceModel
    let createConnection: () -> Void
    let openConnection: (DatabaseConnectionSummary) -> Void
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
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Connections")
                        .font(.system(size: UIScale.pt(compact ? 17 : 20), weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Text("Choose a saved database to open its workspace.")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(palette.inkFaint)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.edith(.secondary))
                .help("Reload saved connections")
                .accessibilityLabel("Reload saved database connections")
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
                detail: "No saved connection matches \"\(search)\".",
                actionTitle: "Clear search",
                action: clearSearch)
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
                .foregroundStyle(palette.inkFaint)
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
        return Button {
            openConnection(connection)
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(15)) {
                HStack(alignment: .top, spacing: UIScale.pt(11)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: UIScale.pt(9))
                            .fill(palette.accent.opacity(highlighted ? 0.18 : 0.11))
                        Image(systemName: connection.product.gallerySymbolName)
                            .font(.system(size: UIScale.pt(16), weight: .semibold))
                            .foregroundStyle(palette.accent)
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
                        Text(connection.product.displayName)
                            .font(.system(size: UIScale.pt(10.5), weight: .medium))
                            .foregroundStyle(palette.inkFaint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(highlighted ? palette.accent : palette.inkFaint)
                        .accessibilityHidden(true)
                }
                HStack(spacing: UIScale.pt(6)) {
                    badge(
                        connection.environmentKind.title,
                        tint: connection.environmentKind == .production
                            ? DashSkin.warn : palette.accent)
                    badge(
                        protectionTitle(connection),
                        tint: protectionColor(connection))
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
                }
                Divider().opacity(0.45)
                HStack(spacing: UIScale.pt(7)) {
                    Image(systemName: sessionSymbol(session))
                        .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                        .foregroundStyle(sessionColor(session))
                        .accessibilityHidden(true)
                    Text(sessionTitle(session))
                        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                        .foregroundStyle(sessionColor(session))
                    Spacer(minLength: 0)
                    Text(connection.readOnlySummary)
                        .font(.system(size: UIScale.pt(9.5), weight: .medium))
                        .foregroundStyle(palette.inkFaint)
                        .lineLimit(1)
                }
            }
            .padding(UIScale.pt(16))
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(178), alignment: .topLeading)
            .background(
                highlighted ? palette.panel : palette.panel.opacity(0.74),
                in: RoundedRectangle(cornerRadius: UIScale.pt(13))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(13))
                    .stroke(
                        highlighted ? palette.accent.opacity(0.72) : palette.line,
                        lineWidth: highlighted ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(13)))
        }
        .buttonStyle(.plain)
        .focused($focusedConnectionID, equals: connection.id)
        .onHover { isHovered in
            hoveredConnectionID = isHovered ? connection.id : nil
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
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, UIScale.pt(7))
            .padding(.vertical, UIScale.pt(4))
            .background(tint.opacity(0.1), in: Capsule())
            .lineLimit(1)
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
                    .foregroundStyle(palette.inkFaint)
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
                    .foregroundStyle(palette.inkFaint)
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
        Task { await model.loadConnections() }
    }

    private func clearSearch() {
        model.searchText = ""
    }

    private func protectionTitle(_ connection: DatabaseConnectionSummary) -> String {
        switch connection.environmentProtection {
        case .standard: "Standard"
        case .confirmationRequired: "Confirm changes"
        case .readOnly: "Read-only environment"
        }
    }

    private func protectionColor(_ connection: DatabaseConnectionSummary) -> Color {
        switch connection.environmentProtection {
        case .standard: palette.inkFaint
        case .confirmationRequired: DashSkin.warn
        case .readOnly: palette.accent
        }
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
    let back: () -> Void
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
            sessionLabel
        }
    }

    private var navigationButton: some View {
        Button(action: back) {
            Label("All connections", systemImage: "chevron.left")
        }
        .buttonStyle(.edith(.secondary))
        .disabled(backDisabled)
        .help(
            backDisabled
                ? "Resolve the active database change before leaving this workspace"
                : "Return to all saved connections"
        )
        .accessibilityHint(
            backDisabled
                ? "Resolve the active database change before returning"
                : "Return to the saved connection cards")
    }

    private var identityRow: some View {
        HStack(spacing: UIScale.pt(10)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .fill(palette.accent.opacity(0.11))
                Image(systemName: connection.product.gallerySymbolName)
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(palette.accent)
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
                    .foregroundStyle(palette.inkFaint)
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

    private var sessionLabel: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: sessionSymbol)
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .foregroundStyle(sessionColor)
                .accessibilityHidden(true)
            Text(sessionTitle)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(sessionColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sessionTitle)
    }

    private var contextTitle: String {
        "\(connection.product.displayName) · \(connection.environmentLabel) · \(connection.environmentProtection.title) · \(connection.readOnlySummary)"
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
