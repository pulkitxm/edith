import AppKit
import EdithDatabase
import EdithKit
import SwiftUI

private enum DatabaseDocumentPresentation: CaseIterable {
    case tree
    case source

    var title: String {
        switch self {
        case .tree: "Tree"
        case .source: "Source"
        }
    }
}

private enum DatabaseWorkbenchMode: String, CaseIterable {
    case browse
    case query

    var title: String {
        switch self {
        case .browse: "Browse"
        case .query: "Query"
        }
    }
}

struct DatabaseWorkbenchView: View {
    let connections: DatabaseConnectionWorkspaceModel
    let explorer: DatabaseObjectExplorerModel
    let data: DatabaseDataWorkspaceModel
    let mutations: DatabaseWorkspaceModel
    var showsObjectNavigator = true
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var documentPresentation = DatabaseDocumentPresentation.tree
    @State private var workbenchMode = DatabaseWorkbenchMode.browse

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: AppTheme(storedName: themeName))
    }
    private var theme: Color { palette.accent }

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
        .background(palette.canvas)
        .task(id: connections.selectedConnection) {
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
                    workbenchMode = .browse
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
                activeRegion(connection)
            } else if showsObjectNavigator {
                HSplitView {
                    DatabaseObjectNavigatorView(
                        explorer: explorer,
                        connection: connection,
                        open: { openObject($0, connection: connection) }
                    )
                    .frame(
                        minWidth: UIScale.pt(190), idealWidth: UIScale.pt(225),
                        maxWidth: UIScale.pt(300))
                    activeRegion(connection)
                        .frame(minWidth: UIScale.pt(460))
                }
            } else {
                activeRegion(connection)
            }
        }
        .onChange(of: explorer.selectedObject) { _, object in
            guard let object, data.selectedObject != object else { return }
            openObject(object, connection: connection)
        }
    }

    @ViewBuilder
    private func activeRegion(_ connection: DatabaseConnectionSummary) -> some View {
        if workbenchMode == .browse {
            dataRegion(connection)
        } else {
            queryRegion(connection)
        }
    }

    private func dataRegion(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            controls(connection)
            DatabaseFilterRibbon(
                data: data,
                connection: connection,
                accent: theme,
                palette: palette,
                apply: { data.browse(connection) })
            results(connection)
        }
    }

    private func controls(_ connection: DatabaseConnectionSummary) -> some View {
        Group {
            if compact {
                VStack(spacing: UIScale.pt(8)) {
                    HStack(spacing: UIScale.pt(8)) {
                        modePicker(connection)
                        objectControls(connection)
                    }
                    HStack(spacing: UIScale.pt(8)) {
                        Spacer(minLength: 0)
                        connectionActions(connection)
                    }
                }
            } else {
                HStack(spacing: UIScale.pt(8)) {
                    modePicker(connection)
                    Rectangle()
                        .fill(palette.line.opacity(0.55))
                        .frame(width: 1, height: UIScale.pt(20))
                    objectControls(connection)
                    connectionActions(connection)
                }
            }
        }
        .padding(UIScale.pt(10))
        .background(palette.panel)
    }

    private func queryRegion(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            queryControls(connection)
            Divider().opacity(0.35)
            results(connection)
        }
    }

    private func queryControls(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            HStack(spacing: UIScale.pt(9)) {
                modePicker(connection)
                Label(selectedObjectTitle, systemImage: selectedObjectSymbol)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if connection.product == .elasticsearch || connection.product == .openSearch {
                    Picker("Query operation", selection: searchQueryOperationBinding(connection)) {
                        ForEach(DatabaseSearchQueryOperation.allCases, id: \.self) { operation in
                            Text(operation.title).tag(operation)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Text("Read only")
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(palette.inkFaint)
                Button("Run") {
                    data.runQuery(connection)
                }
                .buttonStyle(.edith(.primary, tint: theme))
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    data.isLoading
                        || data.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || explorer.selectedObject == nil)
            }
            TextEditor(text: queryTextBinding)
                .font(.system(size: UIScale.pt(11.5), design: .monospaced))
                .foregroundStyle(palette.ink)
                .scrollContentBackground(.hidden)
                .padding(UIScale.pt(7))
                .frame(minHeight: UIScale.pt(86), maxHeight: UIScale.pt(150))
                .background(palette.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                        .stroke(palette.line, lineWidth: 1)
                }
        }
        .padding(UIScale.pt(10))
        .background(palette.canvas)
    }

    private func modePicker(_ connection: DatabaseConnectionSummary) -> some View {
        Picker("Workspace mode", selection: workbenchModeBinding(connection)) {
            ForEach(DatabaseWorkbenchMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: UIScale.pt(142))
    }

    private func connectionActions(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            Button {
                data.browse(connection)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.edith(.borderless))
            .disabled(data.isLoading || explorer.selectedObject == nil)
            .help("Refresh data")
            .accessibilityLabel("Refresh selected object")
            if canInsertData(connection), selectedObjectAcceptsData {
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
                .disabled(
                    (data.fields.isEmpty && !usesDocumentEditor(connection))
                        || mutations.hasTrackedMutation
                )
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
                .foregroundStyle(DashSkin.warn)
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
            } else if !hasAnyDataMutation(connection) {
                Group {
                    if compact {
                        Image(systemName: "eye")
                    } else {
                        Label("Browse only", systemImage: "eye")
                    }
                }
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(.secondary)
                .help(mutationUnavailableHelp(connection))
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
        }
        .frame(maxWidth: compact ? .infinity : UIScale.pt(330), alignment: .leading)
    }

    private func compactObjectPicker(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Menu {
                ForEach(explorer.groups) { group in
                    Section(group.title) {
                        compactGroupAction(group, connection: connection)
                        ForEach(group.objects) { object in
                            Button(object.title) {
                                explorer.select(object.identifier)
                                openObject(object.identifier, connection: connection)
                            }
                        }
                        if group.nextContinuation != nil {
                            Button("Load more objects") {
                                explorer.loadGroup(
                                    group.identifier,
                                    connection: connection,
                                    appending: true)
                            }
                        }
                    }
                }
            } label: {
                Label(selectedObjectTitle, systemImage: selectedObjectSymbol)
                    .lineLimit(1)
            }
            .buttonStyle(.edith(.secondary))
            .disabled(explorer.groups.isEmpty)
            Spacer(minLength: 0)
            Button {
                explorer.load(connection, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel("Reload database objects")
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(height: UIScale.pt(42))
        .background(palette.panel)
    }

    @ViewBuilder
    private func compactGroupAction(
        _ group: DatabaseExplorerGroup,
        connection: DatabaseConnectionSummary
    ) -> some View {
        switch group.state {
        case .idle:
            Button("Load \(group.title)") {
                explorer.loadGroup(group.identifier, connection: connection)
            }
        case .loading:
            Label("Loading \(group.title)", systemImage: "arrow.triangle.2.circlepath")
        case .loaded:
            if group.objects.isEmpty {
                Text("No objects")
            }
        case .failed:
            Button("Retry \(group.title)") {
                explorer.loadGroup(group.identifier, connection: connection)
            }
        }
    }

    @ViewBuilder
    private func results(_ connection: DatabaseConnectionSummary) -> some View {
        switch data.state {
        case .idle:
            if workbenchMode == .query {
                emptyState(
                    symbol: "terminal",
                    title: "Run a query",
                    detail: "Use the native read-only editor above, then press Command-Return.")
            } else if explorer.state == .loading {
                workingState(
                    "Loading objects",
                    "Reading the first available database namespace.",
                    cancel: explorer.cancel)
            } else {
                emptyState(
                    symbol: "sidebar.left",
                    title: "Select an object",
                    detail: "Choose a table or view from the object navigator.")
            }
        case .loading where data.records.isEmpty:
            workingState(
                workbenchMode == .query ? "Running query" : "Loading data",
                workbenchMode == .query
                    ? "Fetching a bounded read-only result."
                    : "Fetching the first bounded page.",
                cancel: data.cancel)
        case .failed(let message) where data.records.isEmpty:
            emptyState(
                symbol: "exclamationmark.triangle",
                title: workbenchMode == .query ? "Query unavailable" : "Data unavailable",
                detail: message,
                actionTitle: "Try again",
                action: {
                    if workbenchMode == .query {
                        data.runQuery(connection)
                    } else {
                        data.browse(connection)
                    }
                })
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
                background: palette.canvas,
                grid: palette.grid,
                ink: palette.ink,
                inkFaint: palette.inkFaint,
                fields: data.fields,
                records: data.records,
                selectedIndex: data.selectedRecordIndex,
                sorts: tableSorts,
                text: { data.text(for: $0) },
                select: { data.selectRecord(at: $0) },
                open: { index in
                    if data.selectedRecordIndex != index {
                        data.selectRecord(at: index)
                    }
                    if workbenchMode == .browse, canUpdateData(connection) {
                        data.beginEditingSelectedRow(connection)
                    }
                },
                rowIsEditable: { index in
                    workbenchMode == .browse
                        && canUpdateData(connection)
                        && !mutations.hasTrackedMutation
                        && data.fields.contains { field in
                            data.canEdit(
                                recordAt: index,
                                field: field.path.segments.joined(separator: "."),
                                connection: connection)
                        }
                },
                canEdit: { index, field in
                    workbenchMode == .browse
                        && canUpdateData(connection)
                        && !mutations.hasTrackedMutation
                        && data.canEdit(recordAt: index, field: field, connection: connection)
                },
                edit: { index, field, text in
                    guard workbenchMode == .browse else { return }
                    guard
                        let request = data.inlineMutationRequest(
                            recordAt: index,
                            field: field,
                            text: text,
                            connection: connection)
                    else { return }
                    mutations.requestSafetyReview(for: request)
                },
                sort: { field, additive in
                    guard workbenchMode == .browse else { return }
                    data.cycleSort(field: field, additive: additive)
                    data.browse(connection)
                })
            Divider().opacity(0.35)
            HStack(spacing: UIScale.pt(9)) {
                if data.isLoading {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: data.cancel)
                        .buttonStyle(.edith(.borderless))
                }
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
            .background(palette.panel)
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
                if usesDocumentEditor(connection) {
                    Picker("Document view", selection: $documentPresentation) {
                        ForEach(DatabaseDocumentPresentation.allCases, id: \.self) { view in
                            Text(view.title).tag(view)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: UIScale.pt(120))
                }
                Spacer(minLength: 0)
                if workbenchMode == .browse, canUpdateData(connection), record.identity != nil {
                    Button("Edit") {
                        data.beginEditingSelectedRow(connection)
                    }
                    .buttonStyle(.edith(.borderless))
                    .disabled(mutations.hasTrackedMutation)
                }
                if workbenchMode == .browse, canDeleteData(connection), record.identity != nil {
                    Button {
                        requestDelete(connection)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(DashSkin.danger)
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
                if usesDocumentEditor(connection), documentPresentation == .source {
                    if let source = data.documentSource(record) {
                        Text(source)
                            .font(.system(size: UIScale.pt(11), design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(UIScale.pt(12))
                    } else {
                        Text("Source view is unavailable for one or more unsupported values.")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                            .padding(UIScale.pt(12))
                    }
                } else {
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
        }
        .background(palette.panel)
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
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(mutations.hasTrackedMutation || !data.canSubmitEditor)
            }
            .padding(UIScale.pt(12))
            Divider().opacity(0.35)
            if usesDocumentEditor(connection) {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    if let error = data.editorError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextEditor(text: documentTextBinding)
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(UIScale.pt(6))
                        .background(palette.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(7)))
                        .overlay {
                            RoundedRectangle(cornerRadius: UIScale.pt(7))
                                .strokeBorder(palette.line)
                        }
                        .accessibilityLabel("\(connection.product.displayName) document JSON")
                }
                .padding(UIScale.pt(12))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(11)) {
                        if let error = data.editorError {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(data.editorFields) { field in
                            editorField(field, connection: connection)
                        }
                    }
                    .padding(UIScale.pt(12))
                }
            }
        }
        .background(palette.panel)
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

    private func workingState(
        _ title: String,
        _ detail: String,
        cancel: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: UIScale.pt(10)) {
            ProgressView()
            Text(title).font(.system(size: UIScale.pt(15), weight: .semibold))
            Text(detail)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
            if let cancel {
                Button("Cancel", action: cancel)
                    .buttonStyle(.edith(.secondary))
            }
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

    private var queryTextBinding: Binding<String> {
        Binding(get: { data.queryText }, set: { data.queryText = $0 })
    }

    private func searchQueryOperationBinding(
        _ connection: DatabaseConnectionSummary
    ) -> Binding<DatabaseSearchQueryOperation> {
        Binding(
            get: { data.searchQueryOperation },
            set: { data.setSearchQueryOperation($0, connection: connection) })
    }

    private func workbenchModeBinding(
        _ connection: DatabaseConnectionSummary
    ) -> Binding<DatabaseWorkbenchMode> {
        Binding(
            get: { workbenchMode },
            set: { mode in
                guard workbenchMode != mode else { return }
                workbenchMode = mode
                guard let object = explorer.selectedObject else { return }
                openObject(object, connection: connection)
            })
    }

    private func openObject(
        _ object: DatabaseObjectIdentifier,
        connection: DatabaseConnectionSummary
    ) {
        if workbenchMode == .query {
            data.prepareQuery(object, connection: connection)
        } else {
            data.open(object, connection: connection)
        }
    }

    private func editorTextBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { data.editorFields.first(where: { $0.id == id })?.text ?? "" },
            set: { data.updateEditorField(id, text: $0) })
    }

    private var documentTextBinding: Binding<String> {
        Binding(get: { data.documentText }, set: { data.updateDocumentText($0) })
    }

    private func editorIncludedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { data.editorFields.first(where: { $0.id == id })?.isIncluded ?? false },
            set: { data.setEditorFieldIncluded(id, included: $0) })
    }

    private func editorTitle(_ connection: DatabaseConnectionSummary) -> String {
        switch data.editorMode {
        case .insert: newItemTitle(connection)
        case .update:
            if connection.product.family == .keyValue {
                "Edit key"
            } else if usesDocumentEditor(connection) {
                "Edit document"
            } else {
                "Edit row"
            }
        case nil:
            if connection.product.family == .keyValue {
                "Key"
            } else if usesDocumentEditor(connection) {
                "Document"
            } else {
                "Row"
            }
        }
    }

    private func newItemTitle(_ connection: DatabaseConnectionSummary) -> String {
        if connection.product.family == .keyValue { return "New key" }
        if usesDocumentEditor(connection) { return "New document" }
        return "New row"
    }

    private func newItemHelp(_ connection: DatabaseConnectionSummary) -> String {
        if connection.product.family == .keyValue { return "Create a string key" }
        if usesDocumentEditor(connection) { return "Add a JSON document" }
        return "Add a row"
    }

    private func detailTitle(_ connection: DatabaseConnectionSummary) -> String {
        if connection.product.family == .keyValue { return "Key details" }
        if usesDocumentEditor(connection) { return "Document details" }
        return "Row details"
    }

    private func deleteTitle(_ connection: DatabaseConnectionSummary) -> String {
        if connection.product.family == .keyValue { return "Delete key" }
        if usesDocumentEditor(connection) { return "Delete document" }
        return "Delete row"
    }

    private func usesDocumentEditor(_ connection: DatabaseConnectionSummary) -> Bool {
        connection.product == .mongoDB || connection.product == .elasticsearch
            || connection.product == .openSearch
    }

    private func requestEditorMutation(_ connection: DatabaseConnectionSummary) {
        guard let request = data.editorMutationRequest(connection) else { return }
        mutations.requestSafetyReview(for: request)
    }

    private func requestDelete(_ connection: DatabaseConnectionSummary) {
        guard let request = data.deleteMutationRequest(connection) else { return }
        mutations.requestSafetyReview(for: request)
    }

    private var tableSorts: [DatabaseSort] {
        data.orderedSorts.map { sort in
            let path =
                data.fields.first {
                    $0.path.segments.joined(separator: ".") == sort.field
                }?.path ?? DatabaseFieldPath(sort.field)
            return DatabaseSort(field: path, direction: sort.direction)
        }
    }

    private var selectedObjectAcceptsData: Bool {
        switch explorer.selectedObject?.kind {
        case .table, .keyspace, .collection, .index:
            true
        default:
            false
        }
    }

    private func canInsertData(_ connection: DatabaseConnectionSummary) -> Bool {
        canUseMutationCapability(.insert, connection: connection)
    }

    private func canUpdateData(_ connection: DatabaseConnectionSummary) -> Bool {
        canUseMutationCapability(.update, connection: connection)
    }

    private func canDeleteData(_ connection: DatabaseConnectionSummary) -> Bool {
        canUseMutationCapability(.delete, connection: connection)
    }

    private func hasAnyDataMutation(_ connection: DatabaseConnectionSummary) -> Bool {
        canInsertData(connection) || canUpdateData(connection) || canDeleteData(connection)
    }

    private func canUseMutationCapability(
        _ capability: DatabaseCapabilityID,
        connection: DatabaseConnectionSummary
    ) -> Bool {
        data.supportsDataMutations(connection)
            && connections.selectedConnectionSupports(capability)
    }

    private func mutationUnavailableHelp(_ connection: DatabaseConnectionSummary) -> String {
        if connection.readOnlyPolicy != .disabled
            || connection.environmentProtection == .readOnly
            || connection.productionPolicy == .prohibitMutations
        {
            return "This connection policy allows browsing only."
        }
        for capability in [
            DatabaseCapabilityID.insert,
            .update,
            .delete,
        ] {
            if let reason = connections.selectedConnectionUnavailableReason(for: capability) {
                return reason
            }
        }
        return "The connected database adapter allows browsing only."
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
