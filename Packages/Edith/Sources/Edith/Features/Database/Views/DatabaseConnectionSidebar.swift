import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseConnectionSidebar: View {
    @Bindable var model: DatabaseConnectionWorkspaceModel
    let createConnection: () -> Void
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            header
            EdithTextField(
                placeholder: "Search saved connections",
                text: $model.searchText,
                icon: "magnifyingglass",
                compact: true,
                clearable: true,
                onSubmit: reload
            )
            .accessibilityLabel("Search saved database connections")
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(UIScale.pt(14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved database connections")
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(8)) {
            Text("Connections")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: createConnection) {
                Image(systemName: "plus")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
            }
            .buttonStyle(.edith(.borderless))
            .help("Add a database connection")
            .accessibilityLabel("Add a database connection")
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
            }
            .buttonStyle(.edith(.borderless))
            .help("Reload saved connections")
            .accessibilityLabel("Reload saved database connections")
        }
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
                title: "No saved connections",
                detail:
                    "Add a database connection here, test it, then save it.",
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
            connectionRows(connections)
        case .partial(let connections):
            stateNotice(
                symbol: "exclamationmark.circle.fill",
                title: "Partial connection list",
                detail: "Some saved connections could not be loaded.",
                tint: .orange)
            connectionRows(connections)
        case .stale(let connections):
            stateNotice(
                symbol: "clock.arrow.circlepath",
                title: "Stale connection list",
                detail: "The saved connection information may be out of date.",
                tint: .orange)
            connectionRows(connections)
        case .failed(let connections, let message):
            stateNotice(
                symbol: "exclamationmark.triangle.fill",
                title: "Connections unavailable",
                detail: message,
                tint: .red,
                retry: true)
            connectionRows(connections)
        }
    }

    private func loadingConnectionRows(_ connections: [DatabaseConnectionSummary]) -> some View {
        SkeletonReplica("Loading saved database connections") {
            Group {
                if connections.isEmpty {
                    LazyVStack(spacing: UIScale.pt(3)) {
                        ForEach(0..<6, id: \.self) { index in
                            loadingConnectionRow(index)
                        }
                    }
                } else {
                    connectionRows(connections)
                }
            }
        }
    }

    private func loadingConnectionRow(_ index: Int) -> some View {
        HStack(spacing: UIScale.pt(9)) {
            Image(systemName: "cylinder")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .frame(width: UIScale.pt(16))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(index.isMultiple(of: 2) ? "Analytics warehouse" : "Primary database")
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    .lineLimit(1)
                Text(index.isMultiple(of: 2) ? "PostgreSQL · Production" : "MySQL · Development")
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Connected")
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UIScale.pt(9))
        .padding(.vertical, UIScale.pt(7))
        .background(Color.clear, in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
    }

    @ViewBuilder
    private func connectionRows(_ connections: [DatabaseConnectionSummary]) -> some View {
        if connections.isEmpty {
            Text("No connection entries are available in this result.")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("No connection entries are available in this result")
        } else {
            LazyVStack(spacing: UIScale.pt(3)) {
                ForEach(connections) { connection in
                    connectionRow(connection)
                }
            }
        }
    }

    private func connectionRow(_ connection: DatabaseConnectionSummary) -> some View {
        let selected = model.selectedConnectionID == connection.id
        let session = model.sessionState(for: connection.id)
        let sessionLabel = sessionTitle(session)
        return Button {
            model.selectConnection(connection.id)
        } label: {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: connection.product.symbolName)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(selected ? theme : Color.secondary)
                    .frame(width: UIScale.pt(16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(connection.name)
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(connection.product.displayName) · \(connection.environmentKind.title)")
                        .font(.system(size: UIScale.pt(10), weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if connection.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: UIScale.pt(8.5)))
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
                connectionSessionSlot(session, label: sessionLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UIScale.pt(9))
            .padding(.vertical, UIScale.pt(7))
            .background(
                selected ? theme.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(7))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .stroke(
                        selected ? theme.opacity(0.45) : Color.clear,
                        lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                connection.name,
                connection.product.displayName,
                connection.environmentSummary,
                connection.isFavorite ? "Favorite" : nil,
                sessionLabel,
                selected ? "Selected" : "Not selected",
            ].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint("Select this database connection")
    }

    @ViewBuilder
    private func connectionSessionSlot(
        _ session: DatabaseConnectionSessionState,
        label: String?
    ) -> some View {
        switch session {
        case .disconnected:
            EmptyView()
        case .connecting, .disconnecting:
            SkeletonReplica(label ?? "Updating connection") {
                Text("Connected")
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            }
        case .connected, .failed, .outcomeUnknown:
            if let label {
                Text(label)
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .foregroundStyle(sessionColor(session))
            }
        }
    }

    private func stateNotice(
        symbol: String,
        title: String,
        detail: String,
        tint: Color,
        retry: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            HStack(spacing: UIScale.pt(7)) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
            }
            Text(detail)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if retry {
                Button("Try again", action: reload)
                    .buttonStyle(.edith(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(10))
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func emptyState(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(24), weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: UIScale.pt(13), weight: .semibold))
            Text(detail)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action ?? reload)
                .buttonStyle(.edith(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, UIScale.pt(10))
        .accessibilityElement(children: .contain)
    }

    private func reload() {
        Task { await model.loadConnections() }
    }

    private func clearSearch() {
        model.searchText = ""
    }

    private func sessionTitle(_ state: DatabaseConnectionSessionState) -> String? {
        switch state {
        case .disconnected: nil
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Connection issue"
        case .outcomeUnknown: "Connection status unknown"
        }
    }

    private func sessionColor(_ state: DatabaseConnectionSessionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .disconnecting: theme
        case .failed: .red
        case .outcomeUnknown: .orange
        case .disconnected: .secondary
        }
    }
}

private extension DatabaseProduct {
    var symbolName: String {
        switch family {
        case .relational: "tablecells"
        case .keyValue: "key.horizontal"
        case .document: "doc.text"
        case .search: "magnifyingglass.circle"
        case .analytical: "chart.xyaxis.line"
        }
    }
}
