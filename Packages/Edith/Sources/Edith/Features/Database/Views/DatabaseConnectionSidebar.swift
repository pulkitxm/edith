import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseConnectionSidebar: View {
    @Bindable var model: DatabaseConnectionWorkspaceModel
    let createConnection: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
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
                .foregroundStyle(DashSkin.inkFaint(dark))
                .textCase(.uppercase)
                .tracking(0.5)
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
            emptyState(
                symbol: "cylinder.split.1x2",
                title: "Connections not loaded",
                detail: "Load saved connections through the authenticated local broker.",
                actionTitle: "Load connections")
        case .loading(let connections):
            stateNotice(
                symbol: "arrow.triangle.2.circlepath",
                title: "Loading connections",
                detail: "Saved connection information is being refreshed.",
                tint: DashSkin.accent(dark),
                progress: true)
            connectionRows(connections)
        case .empty:
            emptyState(
                symbol: "cylinder.split.1x2",
                title: "No saved connections",
                detail:
                    "Add a database connection here, test it through the local broker, then save it.",
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
                tint: DashSkin.warn)
            connectionRows(connections)
        case .stale(let connections):
            stateNotice(
                symbol: "clock.arrow.circlepath",
                title: "Stale connection list",
                detail: "The broker returned saved information that may be out of date.",
                tint: DashSkin.warn)
            connectionRows(connections)
        case .failed(let connections, let message):
            stateNotice(
                symbol: "exclamationmark.triangle.fill",
                title: "Connections unavailable",
                detail: message,
                tint: DashSkin.danger,
                retry: true)
            connectionRows(connections)
        }
    }

    @ViewBuilder
    private func connectionRows(_ connections: [DatabaseConnectionSummary]) -> some View {
        if connections.isEmpty {
            Text("No connection entries are available in this result.")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("No connection entries are available in this result")
        } else {
            LazyVStack(spacing: UIScale.pt(7)) {
                ForEach(connections) { connection in
                    connectionRow(connection)
                }
            }
        }
    }

    private func connectionRow(_ connection: DatabaseConnectionSummary) -> some View {
        let selected = model.selectedConnectionID == connection.id
        let sessionLabel = sessionTitle(model.sessionState(for: connection.id))
        return Button {
            model.selectConnection(connection.id)
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                HStack(spacing: UIScale.pt(7)) {
                    Image(systemName: connection.product.symbolName)
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                        .foregroundStyle(
                            selected ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                        )
                        .accessibilityHidden(true)
                    Text(connection.name)
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if connection.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.gold)
                            .accessibilityHidden(true)
                    }
                }
                Text("\(connection.product.displayName) · \(connection.environmentKind.title)")
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                if let sessionLabel {
                    Text(sessionLabel)
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(sessionColor(model.sessionState(for: connection.id)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(9))
            .background(
                selected ? DashSkin.accent(dark).opacity(0.11) : DashSkin.paper(dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(9))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(9))
                    .stroke(
                        selected ? DashSkin.accent(dark) : DashSkin.line(dark),
                        lineWidth: selected ? 1.5 : 1)
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

    private func stateNotice(
        symbol: String,
        title: String,
        detail: String,
        tint: Color,
        progress: Bool = false,
        retry: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            HStack(spacing: UIScale.pt(7)) {
                if progress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
            }
            Text(detail)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
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
                .foregroundStyle(DashSkin.inkFaint(dark))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: UIScale.pt(13), weight: .semibold))
            Text(detail)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
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
        case .connected: DashSkin.ok
        case .connecting, .disconnecting: DashSkin.accent(dark)
        case .failed: DashSkin.danger
        case .outcomeUnknown: DashSkin.warn
        case .disconnected: DashSkin.inkFaint(dark)
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
