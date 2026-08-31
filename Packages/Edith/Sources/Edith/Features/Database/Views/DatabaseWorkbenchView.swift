import AppKit
import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseWorkbenchView: View {
    let connections: DatabaseConnectionWorkspaceModel
    let explorer: DatabaseObjectExplorerModel
    let data: DatabaseDataWorkspaceModel
    let mutations: DatabaseWorkspaceModel
    var showsObjectNavigator = true
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue
    @Environment(\.compactLayout) private var compact

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        Group {
            if let connection = connections.selectedConnection {
                sessionContent(connection)
            } else {
                emptyState(
                    symbol: "cylinder.split.1x2",
                    title: "Choose a connection",
                    detail: "Select a connection or add one to start working with data.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: connections.selectedConnectionID) {
            data.prepare(for: connections.selectedConnection)
            explorer.prepare(for: connections.selectedConnection)
        }
    }

    @ViewBuilder
    private func sessionContent(_ connection: DatabaseConnectionSummary) -> some View {
        switch connections.selectedSessionState {
        case .disconnected:
            VStack(spacing: UIScale.pt(16)) {
                Image(systemName: productSymbol(connection.product))
                    .font(.system(size: UIScale.pt(40), weight: .light))
                    .foregroundStyle(theme)
                Text(connection.name)
                    .font(.system(size: UIScale.pt(21), weight: .semibold))
                Text("\(connection.product.displayName) · \(connection.environmentLabel)")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                Button("Connect") {
                    Task { await connections.connectSelected() }
                }
                .buttonStyle(.edith(.primary, tint: theme))
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connecting:
            workingState("Connecting", "Opening a secure database session.")
        case .connected:
            workspace(connection)
                .task(id: connection.id) {
                    explorer.load(connection)
                }
        case .disconnecting:
            workingState("Disconnecting", "Closing the database session.")
        case .failed(let message, _), .outcomeUnknown(let message, _):
            emptyState(
                symbol: "exclamationmark.triangle",
                title: "Connection unavailable",
                detail: message,
                actionTitle: "Try again",
                action: { Task { await connections.connectSelected() } })
        }
    }

    private func workspace(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            if compact {
                compactObjectPicker(connection)
                Divider().opacity(0.35)
                dataRegion(connection)
            } else if showsObjectNavigator {
                HSplitView {
                    DatabaseObjectNavigatorView(
                        explorer: explorer,
                        connection: connection,
                        open: { data.open($0, connection: connection) }
                    )
                    .frame(
                        minWidth: UIScale.pt(190), idealWidth: UIScale.pt(225),
                        maxWidth: UIScale.pt(300))
                    dataRegion(connection)
                        .frame(minWidth: UIScale.pt(460))
                }
            } else {
                dataRegion(connection)
            }
        }
        .onChange(of: explorer.selectedObject) { _, object in
            guard let object, data.selectedObject != object else { return }
            data.open(object, connection: connection)
        }
    }

    private func dataRegion(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            controls(connection)
            Divider().opacity(0.35)
            results(connection)
        }
    }

    private func controls(_ connection: DatabaseConnectionSummary) -> some View {
        Group {
            if compact {
                VStack(spacing: UIScale.pt(8)) {
                    objectControls(connection)
                    HStack(spacing: UIScale.pt(8)) {
                        filterControls(connection)
                        connectionActions(connection)
                    }
                }
            } else {
                HStack(spacing: UIScale.pt(8)) {
                    objectControls(connection)
                    Divider().frame(height: UIScale.pt(20))
                    filterControls(connection)
                    connectionActions(connection)
                }
            }
        }
        .padding(UIScale.pt(10))
    }

    private func connectionActions(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            if data.supportsDataMutations(connection),
                explorer.selectedObject?.kind == .table
                    || explorer.selectedObject?.kind == .keyspace
            {
                Button {
                    data.beginInsert(connection)
                } label: {
                    if compact {
                        Image(systemName: "plus")
                    } else {
                        Label(newItemTitle(connection), systemImage: "plus")
                    }
                }
                .buttonStyle(.edith(.primary, tint: theme))
                .disabled(data.fields.isEmpty || mutations.hasTrackedMutation)
                .help(newItemHelp(connection))
            }
            if connection.environmentKind == .production {
                Group {
                    if compact {
                        Image(systemName: "exclamationmark.shield.fill")
                    } else {
                        Label("Production", systemImage: "exclamationmark.shield.fill")
                    }
                }
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(.orange)
                .help("Production connection")
                .accessibilityLabel("Production connection")
            } else if connection.readOnlyPolicy != .disabled {
                Group {
                    if compact {
                        Image(systemName: "lock.fill")
                    } else {
                        Label("Read only", systemImage: "lock.fill")
                    }
                }
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(.secondary)
                .help("Read-only connection")
                .accessibilityLabel("Read-only connection")
            } else if !data.supportsDataMutations(connection) {
                Group {
                    if compact {
                        Image(systemName: "eye")
                    } else {
                        Label("Browse only", systemImage: "eye")
                    }
                }
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(.secondary)
                .help("Data editing is not available for this database yet")
            }
            Button {
                data.cancel()
                Task { await connections.disconnectSelected() }
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.edith(.borderless))
            .help("Disconnect \(connection.name)")
            .accessibilityLabel("Disconnect \(connection.name)")
        }
    }

    private func objectControls(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            Image(systemName: selectedObjectSymbol)
                .foregroundStyle(theme)
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(selectedObjectTitle)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .lineLimit(1)
                if let selected = explorer.selectedObject, selected.path.count > 1 {
                    Text(selected.path.dropLast().joined(separator: " / "))
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                data.browse(connection)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.edith(.borderless))
            .disabled(data.isLoading || explorer.selectedObject == nil)
            .help("Refresh data")
            .accessibilityLabel("Refresh selected object")
        }
        .frame(maxWidth: compact ? .infinity : UIScale.pt(330), alignment: .leading)
    }

    private func compactObjectPicker(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Menu {
                ForEach(explorer.groups) { group in
                    Section(group.title) {
                        ForEach(group.objects) { object in
                            Button(object.title) {
                                explorer.select(object.identifier)
                                data.open(object.identifier, connection: connection)
                            }
                        }
                    }
                }
            } label: {
                Label(selectedObjectTitle, systemImage: selectedObjectSymbol)
                    .lineLimit(1)
            }
            .buttonStyle(.edith(.secondary))
            .disabled(explorer.groups.allSatisfy { $0.objects.isEmpty })
            Spacer(minLength: 0)
            Button {
                explorer.load(connection)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel("Reload database objects")
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(height: UIScale.pt(42))
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func filterControls(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            Menu {
                Button("No filter") {
                    data.filterField = ""
                    data.filterValue = ""
                }
                ForEach(data.fields, id: \.path) { field in
                    if field.isFilterable {
                        Button(field.displayName) {
                            data.filterField = field.path.segments.joined(separator: ".")
                        }
                    }
                }
            } label: {
                Label(
                    data.filterField.isEmpty ? "Filter" : data.filterField,
                    systemImage: "line.3.horizontal.decrease"
                )
                .lineLimit(1)
            }
            .buttonStyle(.edith(.secondary))
            .disabled(data.fields.isEmpty)
            TextField("Value", text: filterBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: UIScale.pt(180))
                .disabled(data.filterField.isEmpty)
                .onSubmit { data.browse(connection) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func results(_ connection: DatabaseConnectionSummary) -> some View {
        switch data.state {
        case .idle:
            if explorer.state == .loading {
                workingState("Loading objects", "Reading the first available database namespace.")
            } else {
                emptyState(
                    symbol: "sidebar.left",
                    title: "Select an object",
                    detail: "Choose a table or view from the object navigator.")
            }
        case .loading where data.records.isEmpty:
            workingState("Loading data", "Fetching the first bounded page.")
        case .failed(let message) where data.records.isEmpty:
            emptyState(
                symbol: "exclamationmark.triangle",
                title: "Data unavailable",
                detail: message,
                actionTitle: "Try again",
                action: { data.browse(connection) })
        case .loading, .loaded, .failed:
            populatedResults(connection)
        }
    }

    private func populatedResults(_ connection: DatabaseConnectionSummary) -> some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    grid(connection)
                    if data.editorMode != nil || data.selectedRecord != nil {
                        Divider().opacity(0.35)
                        inspectorRegion(connection).frame(maxHeight: UIScale.pt(320))
                    }
                }
            } else {
                if data.editorMode != nil || data.selectedRecord != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            grid(connection)
                                .frame(minWidth: UIScale.pt(480))
                            Divider().opacity(0.35)
                            inspectorRegion(connection).frame(width: UIScale.pt(300))
                        }
                        VStack(spacing: 0) {
                            grid(connection)
                            Divider().opacity(0.35)
                            inspectorRegion(connection).frame(maxHeight: UIScale.pt(260))
                        }
                    }
                } else {
                    grid(connection)
                }
            }
        }
    }

    private func grid(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            DatabaseNativeTableView(
                accent: theme,
                fields: data.fields,
                records: data.records,
                selectedIndex: data.selectedRecordIndex,
                sortField: data.sortField,
                sortDirection: data.sortDirection,
                text: { data.text(for: $0) },
                select: { data.selectRecord(at: $0) },
                open: { index in
                    if data.selectedRecordIndex != index {
                        data.selectRecord(at: index)
                    }
                    if data.supportsDataMutations(connection) {
                        data.beginEditingSelectedRow(connection)
                    }
                },
                canEdit: { index, field in
                    !mutations.hasTrackedMutation
                        && data.canEdit(recordAt: index, field: field, connection: connection)
                },
                edit: { index, field, text in
                    guard
                        let request = data.inlineMutationRequest(
                            recordAt: index,
                            field: field,
                            text: text,
                            connection: connection)
                    else { return }
                    mutations.requestSafetyReview(for: request)
                },
                sort: { field, direction in
                    data.sortField = field
                    data.sortDirection = direction
                    data.browse(connection)
                })
            Divider().opacity(0.35)
            HStack(spacing: UIScale.pt(9)) {
                if data.isLoading { ProgressView().controlSize(.small) }
                Text(resultSummary)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if data.hasNextPage {
                    Button("Load more") { data.loadNextPage(connection) }
                        .buttonStyle(.edith(.secondary))
                        .disabled(data.isLoading)
                }
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(38))
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func inspectorRegion(_ connection: DatabaseConnectionSummary) -> some View {
        if data.editorMode != nil {
            editor(connection)
        } else if let record = data.selectedRecord {
            inspector(record, connection: connection)
        }
    }

    private func inspector(
        _ record: DatabaseRecord,
        connection: DatabaseConnectionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(detailTitle(connection))
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                Spacer(minLength: 0)
                if data.supportsDataMutations(connection), record.identity != nil {
                    Button("Edit") {
                        data.beginEditingSelectedRow(connection)
                    }
                    .buttonStyle(.edith(.borderless))
                    .disabled(mutations.hasTrackedMutation)
                    Button {
                        requestDelete(connection)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.edith(.borderless))
                    .disabled(mutations.hasTrackedMutation)
                    .accessibilityLabel(deleteTitle(connection))
                }
                Button {
                    if let index = data.selectedRecordIndex { data.selectRecord(at: index) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.edith(.borderless))
            }
            .padding(UIScale.pt(12))
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    ForEach(Array(record.fields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(field.name)
                                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(data.text(for: field.value))
                                .font(.system(size: UIScale.pt(11), design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(UIScale.pt(12))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func editor(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UIScale.pt(8)) {
                Text(editorTitle(connection))
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                Spacer(minLength: 0)
                Button("Cancel") { data.cancelEditor() }
                    .buttonStyle(.edith(.borderless))
                Button("Review") { requestEditorMutation(connection) }
                    .buttonStyle(.edith(.primary, tint: theme))
                    .disabled(mutations.hasTrackedMutation || !data.canSubmitEditor)
            }
            .padding(UIScale.pt(12))
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(11)) {
                    if let error = data.editorError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(data.editorFields) { field in
                        editorField(field, connection: connection)
                    }
                }
                .padding(UIScale.pt(12))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func editorField(
        _ field: DatabaseRowFieldDraft,
        connection: DatabaseConnectionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(6)) {
                Toggle("", isOn: editorIncludedBinding(field.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!field.isEditable)
                    .help("Include \(field.id) in this change")
                Text(field.id)
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(.primary)
                Text(field.typeName)
                    .font(.system(size: UIScale.pt(9.5)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if field.isIdentity {
                    Label("key", systemImage: "key.fill")
                        .labelStyle(.titleOnly)
                        .font(.system(size: UIScale.pt(9.5), weight: .medium))
                        .foregroundStyle(.secondary)
                } else if field.isEditable {
                    if field.isIncluded {
                        Button {
                            data.resetEditorField(field.id)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.edith(.borderless))
                        .help("Reset \(field.id)")
                    }
                    if connection.product.family == .keyValue {
                        if field.id == "ttlMilliseconds" {
                            Button("No expiry") {
                                data.updateEditorField(field.id, text: "-1")
                            }
                            .buttonStyle(.edith(.borderless))
                            .font(.system(size: UIScale.pt(9.5), weight: .medium))
                        }
                    } else {
                        Button("NULL") { data.setEditorFieldNull(field.id) }
                            .buttonStyle(.edith(.borderless))
                            .font(.system(size: UIScale.pt(9.5), weight: .medium))
                    }
                }
            }
            TextField("Value", text: editorTextBinding(field.id))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                .disabled(!field.isEditable)
        }
        .opacity(field.isEditable ? 1 : 0.62)
    }

    private func workingState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: UIScale.pt(10)) {
            ProgressView()
            Text(title).font(.system(size: UIScale.pt(15), weight: .semibold))
            Text(detail)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: UIScale.pt(11)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(32), weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: UIScale.pt(17), weight: .semibold))
            Text(detail)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(410))
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.edith(.primary, tint: theme))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(UIScale.pt(26))
    }

    private var filterBinding: Binding<String> {
        Binding(get: { data.filterValue }, set: { data.filterValue = $0 })
    }

    private func editorTextBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { data.editorFields.first(where: { $0.id == id })?.text ?? "" },
            set: { data.updateEditorField(id, text: $0) })
    }

    private func editorIncludedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { data.editorFields.first(where: { $0.id == id })?.isIncluded ?? false },
            set: { data.setEditorFieldIncluded(id, included: $0) })
    }

    private func editorTitle(_ connection: DatabaseConnectionSummary) -> String {
        switch data.editorMode {
        case .insert: newItemTitle(connection)
        case .update: connection.product.family == .keyValue ? "Edit key" : "Edit row"
        case nil: connection.product.family == .keyValue ? "Key" : "Row"
        }
    }

    private func newItemTitle(_ connection: DatabaseConnectionSummary) -> String {
        connection.product.family == .keyValue ? "New key" : "New row"
    }

    private func newItemHelp(_ connection: DatabaseConnectionSummary) -> String {
        connection.product.family == .keyValue ? "Create a string key" : "Add a row"
    }

    private func detailTitle(_ connection: DatabaseConnectionSummary) -> String {
        connection.product.family == .keyValue ? "Key details" : "Row details"
    }

    private func deleteTitle(_ connection: DatabaseConnectionSummary) -> String {
        connection.product.family == .keyValue ? "Delete key" : "Delete row"
    }

    private func requestEditorMutation(_ connection: DatabaseConnectionSummary) {
        guard let request = data.editorMutationRequest(connection) else { return }
        mutations.requestSafetyReview(for: request)
    }

    private func requestDelete(_ connection: DatabaseConnectionSummary) {
        guard let request = data.deleteMutationRequest(connection) else { return }
        mutations.requestSafetyReview(for: request)
    }

    private var resultSummary: String {
        var parts = ["\(data.records.count.formatted()) shown"]
        if let metadata = data.metadata {
            parts.append(metadata.completeness.state.rawValue)
            if let duration = metadata.timing?.durationMilliseconds {
                parts.append("\(duration) ms")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var selectedObjectTitle: String {
        explorer.selectedObject?.path.last ?? "Select an object"
    }

    private var selectedObjectSymbol: String {
        switch explorer.selectedObject?.kind {
        case .table: "tablecells"
        case .view, .materializedView: "rectangle.stack"
        case .index: "list.bullet.rectangle"
        case .collection: "doc.on.doc"
        case .keyspace: "key.horizontal"
        default: "sidebar.left"
        }
    }

    private func productSymbol(_ product: DatabaseProduct) -> String {
        switch product.family {
        case .relational: "tablecells"
        case .keyValue: "key.horizontal"
        case .document: "doc.text"
        case .search: "magnifyingglass"
        case .analytical: "chart.xyaxis.line"
        }
    }
}
