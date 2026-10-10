import AppKit
import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DatabaseWorkbenchTabView: View {
    let connections: DatabaseConnectionWorkspaceModel
    let explorer: DatabaseObjectExplorerModel
    let mutations: DatabaseWorkspaceModel
    let connection: DatabaseConnectionSummary
    let tab: DatabaseTableTab?
    let data: DatabaseDataWorkspaceModel
    let isActive: Bool
    let palette: DatabaseThemePalette
    @Environment(\.compactLayout) private var compact
    @State private var emptyColumns = DatabaseColumnsModel()
    private var columns: DatabaseColumnsModel { tab?.columns ?? emptyColumns }
    private var mode: DatabaseWorkbenchMode { tab?.mode ?? .browse }
    private var showsInspector: Bool { data.editorMode != nil || data.selectedRecord != nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.35)
            if mode == .structure {
                DatabaseStructureView(fields: data.objectFields, palette: palette)
            } else {
                if mode == .query { queryEditor }
                results
            }
        }
        .onChange(of: data.fields, initial: true) { _, _ in synchronizeColumns() }
        .onChange(of: data.selectedObject) { _, _ in synchronizeColumns() }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(10)) {
                modePicker
                objectTitle
                Spacer(minLength: 0)
                toolbarActions.fixedSize()
            }
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                modePicker
                HStack {
                    Spacer(minLength: 0); toolbarActions
                }
            }
        }
        .padding(UIScale.pt(12)).background(palette.panel)
    }

    private var modePicker: some View {
        Group {
            if compact {
                Picker("Workspace mode", selection: modeSelection) {
                    ForEach(DatabaseWorkbenchMode.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.large)
                .font(.edithText(.body))
                .accessibilityLabel("Workspace mode")
            } else {
                EdithSegmentedPicker(
                    "Workspace mode", selection: modeSelection,
                    options: DatabaseWorkbenchMode.allCases, label: { $0.title })
                    .labelsHidden()
            }
        }
        .frame(maxWidth: UIScale.pt(208))
        .disabled(tab == nil || data.isLoading)
    }

    private var modeSelection: Binding<DatabaseWorkbenchMode> {
        Binding(get: { mode }, set: { tab?.selectMode($0, connection: connection) })
    }

    @ViewBuilder private var objectTitle: some View {
        if !compact {
            Text(data.selectedObject?.path.joined(separator: ".") ?? "Select an object")
                .font(.system(size: UIScale.pt(11), weight: .medium)).lineLimit(1)
                .foregroundStyle(palette.inkSoft)
        }
    }

    private var toolbarActions: some View {
        HStack(spacing: UIScale.pt(10)) {
            if connection.environmentKind == .production {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(DashSkin.warn)
                    .help("Production connection").accessibilityLabel("Production connection")
            } else if connection.readOnlyPolicy != .disabled {
                Image(systemName: "lock.fill").foregroundStyle(palette.inkFaint)
                    .help("Read-only connection").accessibilityLabel("Read-only connection")
            }
            if mode == .browse {
                Button {
                    data.browse(connection)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.edith(.iconOnly)).help("Refresh data")
                .accessibilityLabel("Refresh selected object")
                .disabled(data.isLoading || data.selectedObject == nil)
                if supports(.insert) {
                    Button {
                        data.beginInsert(connection)
                    } label: {
                        Label(newItemTitle, systemImage: "plus")
                    }
                    .buttonStyle(.edith(.primary, tint: palette.accent))
                    .disabled(
                        data.isLoading || mutations.hasTrackedMutation
                            || (data.fields.isEmpty && !usesDocuments))
                }
            }
            Menu {
                Button("Disconnect", systemImage: "power") {
                    data.cancel()
                    Task { await connections.disconnectSelected() }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More database actions")
        }
    }

    private var queryEditor: some View {
        VStack(spacing: UIScale.pt(8)) {
            WrapHStack(spacing: UIScale.pt(10)) {
                Label("Read-only query", systemImage: "terminal")
                    .font(.system(size: UIScale.pt(10.5), weight: .medium)).foregroundStyle(
                        palette.inkSoft)
                Spacer()
                if connection.product == .elasticsearch || connection.product == .openSearch {
                    Picker(
                        "Query operation",
                        selection: Binding(
                            get: { data.searchQueryOperation },
                            set: { data.setSearchQueryOperation($0, connection: connection) })
                    ) {
                        ForEach(DatabaseSearchQueryOperation.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }.labelsHidden().pickerStyle(.menu).disabled(data.isLoading)
                }
                Menu {
                    if let tab {
                        ForEach(tab.history.entries) { entry in
                            Button(
                                String(entry.text.prefix(80)).replacingOccurrences(
                                    of: "\n", with: " ")
                            ) {
                                tab.restoreQuery(entry, connection: connection)
                            }
                        }
                        Divider()
                        Button("Clear history") { tab.history.clear() }
                    }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(data.isLoading || tab?.history.entries.isEmpty != false)
                .help("Recent queries for this tab, kept in memory only")
                Button(data.isLoading ? "Cancel" : "Run") {
                    if data.isLoading { data.cancel() } else { tab?.runQuery(connection) }
                }
                .buttonStyle(.edith(.primary, tint: palette.accent))
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    !data.isLoading
                        && (tab == nil
                            || data.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty)
                )
            }
            TextEditor(text: Binding(get: { data.queryText }, set: { data.queryText = $0 }))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .foregroundStyle(palette.ink).scrollContentBackground(.hidden)
                .padding(UIScale.pt(8)).frame(minHeight: UIScale.pt(96), maxHeight: UIScale.pt(180))
                .background(palette.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(6)).strokeBorder(palette.line)
                }
                .accessibilityLabel("Database query").disabled(data.isLoading)
        }.padding(UIScale.pt(12)).background(palette.canvas)
    }

    @ViewBuilder
    private var results: some View {
        if data.state == .idle {
            if explorer.state == .loading {
                loadingResults(label: "Loading database objects", cancel: explorer.cancel)
            } else {
                DatabaseWorkbenchEmptyState(
                    symbol: mode == .query ? "terminal" : "sidebar.left",
                    title: mode == .query ? "Run a query" : "Select an object",
                    detail: mode == .query
                        ? "Press Command-Return to run the query above."
                        : "Choose a table or view from the object navigator.")
            }
        } else if data.isLoading && data.records.isEmpty {
            loadingResults(
                label: mode == .query ? "Running query" : "Loading data", cancel: data.cancel)
        } else if showsInspector {
            GeometryReader { geometry in
                if !compact && geometry.size.width >= UIScale.pt(780) + 1 {
                    HStack(spacing: 0) {
                        grid.frame(width: geometry.size.width - UIScale.pt(300) - 1)
                        Divider()
                        inspector.frame(width: UIScale.pt(300))
                    }
                } else {
                    VSplitView {
                        grid
                            .frame(minHeight: min(UIScale.pt(160), geometry.size.height * 0.6))
                        inspector.frame(
                            minHeight: UIScale.pt(0),
                            idealHeight: min(UIScale.pt(220), geometry.size.height * 0.4),
                            maxHeight: geometry.size.height * 0.5)
                    }
                }
            }
        } else {
            grid
        }
    }

    private var inspector: some View {
        DatabaseRecordInspector(
            data: data, mutations: mutations, connection: connection, palette: palette,
            canUpdate: mode == .browse && supports(.update),
            canDelete: mode == .browse && supports(.delete))
    }

    private var grid: some View {
        VStack(spacing: 0) {
            if mode == .browse {
                DatabaseFilterRibbon(
                    data: data, connection: connection, columns: columns, accent: palette.accent,
                    palette: palette, apply: { data.browse(connection) })
            }
            if case .failed(let message) = data.state {
                HStack(spacing: UIScale.pt(8)) {
                    Label(message, systemImage: "exclamationmark.circle").lineLimit(2)
                    Spacer()
                    if data.hasActiveFilters && mode == .browse {
                        Button("Clear filters") {
                            data.clearFilters(); data.browse(connection)
                        }
                    }
                    Button("Try again") {
                        if mode == .query {
                            tab?.runQuery(connection)
                        } else {
                            data.browse(connection)
                        }
                    }
                }
                .font(.system(size: UIScale.pt(11))).foregroundStyle(DashSkin.warn)
                .padding(UIScale.pt(10)).background(DashSkin.warn.opacity(0.08))
            }
            nativeGrid.clipped()
            Divider().opacity(0.35)
            statusBar
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nativeGrid: some View {
        DatabaseNativeTableView(
            accent: palette.accent, background: palette.canvas, grid: palette.grid,
            ink: palette.ink, inkFaint: palette.inkFaint,
            fields: columns.columns.isEmpty ? data.fields : columns.visibleFields,
            records: data.records,
            selectedIndex: data.selectedRecordIndex,
            sorts: data.orderedSorts.map { sort in
                DatabaseSort(
                    field: data.fields.first {
                        $0.path.segments.joined(separator: ".") == sort.field
                    }?.path ?? DatabaseFieldPath(sort.field), direction: sort.direction)
            },
            nextContinuation: data.nextContinuation, isLoading: data.isLoading,
            columnWidth: { columns.width(for: $0) }, text: { data.text(for: $0) },
            loadMore: { data.loadNextPage(connection) }, select: { data.selectRecord(at: $0) },
            open: { index in
                if data.selectedRecordIndex != index { data.selectRecord(at: index) }
                if editingEnabled && data.canMutateSelectedRecord(.update, connection: connection) {
                    data.beginEditingSelectedRow(connection)
                }
            },
            rowIsEditable: { index in
                editingEnabled
                    && data.fields.contains {
                        data.canEdit(
                            recordAt: index, field: $0.path.segments.joined(separator: "."),
                            connection: connection)
                    }
            },
            canEdit: { index, field in
                editingEnabled && !data.usesStructuredEditor(field: field, connection: connection)
                    && data.canEdit(recordAt: index, field: field, connection: connection)
            },
            edit: { index, field, text in
                guard editingEnabled,
                    let request = data.inlineMutationRequest(
                        recordAt: index, field: field, text: text, connection: connection)
                else { return }
                mutations.requestSafetyReview(for: request)
            },
            sort: { field, additive in
                guard mode == .browse else { return }
                data.cycleSort(field: field, additive: additive)
                data.browse(connection)
            }, resizeColumn: { columns.setWidth($1, for: $0) },
            contentRevision: data.recordsRevision, appendedFrom: data.recordsAppendedFrom,
            editingEnabled: editingEnabled, isActive: isActive, scale: UIScale.current,
            scrollOffset: tab?.scrollOffset ?? .zero,
            saveScrollOffset: { [tab] in tab?.scrollOffset = $0 })
    }

    private var statusBar: some View {
        HStack(spacing: UIScale.pt(10)) {
            Text(resultSummary).font(.system(size: UIScale.pt(10.5))).foregroundStyle(
                palette.inkSoft
            ).lineLimit(1)
            if data.isLoading {
                Button("Cancel", action: data.cancel).buttonStyle(.edith(.borderless))
            }
            Spacer(minLength: 0)
            if data.hasNextPage {
                Button("Load more") { data.loadNextPage(connection) }.disabled(data.isLoading)
                    .buttonStyle(.edith(.borderless))
            }
            Menu {
                ForEach(DatabaseDataWorkspaceModel.pageSizeOptions, id: \.self) { size in
                    Button("\(size) rows") {
                        data.setPageSize(size)
                        if mode == .query {
                            data.runQuery(connection)
                        } else {
                            data.browse(connection)
                        }
                    }
                }
            } label: {
                Text("\(data.pageSize) per page").font(.system(size: UIScale.pt(10)))
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(data.isLoading)
            .accessibilityLabel("Page size, \(data.pageSize) rows")
        }.padding(.horizontal, UIScale.pt(12)).frame(height: UIScale.pt(36)).background(
            palette.panel)
    }

    private func loadingResults(label: String, cancel: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottomLeading) {
            SkeletonGroup {
                VStack(spacing: UIScale.pt(16)) {
                    ForEach(0..<12, id: \.self) { _ in
                        HStack(spacing: UIScale.pt(30)) {
                            SkeletonBlock(width: 18, height: 9)
                            ForEach(0..<(compact ? 3 : 5), id: \.self) { _ in
                                SkeletonBlock(width: 80, height: 9)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(UIScale.pt(14))
            }.accessibilityLabel(label)
            Button("Cancel", action: cancel).buttonStyle(.edith(.secondary)).padding(UIScale.pt(12))
        }
    }

    private var resultSummary: String {
        var parts = ["\(data.records.count.formatted()) rows loaded"]
        if let count = data.metadata?.count, let value = count.value {
            parts.append("\(count.accuracy == .exact ? "" : "~")\(value.formatted()) total")
        }
        if let duration = data.metadata?.timing?.durationMilliseconds {
            parts.append("\(duration) ms")
        }
        if let completeness = data.metadata?.completeness,
            completeness.state == .truncated || completeness.state == .partial
        {
            parts.append(completeness.state.rawValue)
        }
        return parts.joined(separator: " · ")
    }

    private var usesDocuments: Bool { DatabaseDataWorkspaceModel.usesDocumentEditor(connection) }
    private var newItemTitle: String {
        connection.product.family == .keyValue
            ? "New key" : usesDocuments ? "New document" : "New row"
    }
    private var editingEnabled: Bool {
        mode == .browse && supports(.update) && !mutations.hasTrackedMutation
    }

    private func supports(_ capability: DatabaseCapabilityID) -> Bool {
        guard data.supportsDataMutation(capability, connection: connection),
            connections.selectedConnectionSupports(capability), let kind = data.selectedObject?.kind
        else { return false }
        return switch connection.product.family {
        case .relational, .analytical: kind == .table
        case .keyValue: kind == .keyspace
        case .document: kind == .collection
        case .search: kind == .index
        }
    }

    private func synchronizeColumns() {
        guard let object = data.selectedObject else { columns.clear(); return }
        columns.synchronize(connectionID: connection.id, object: object, fields: data.fields)
    }
}
