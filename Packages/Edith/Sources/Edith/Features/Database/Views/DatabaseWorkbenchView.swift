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
    @State private var columns = DatabaseColumnsModel()

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
            if let connection = connections.selectedConnection {
                synchronizeColumns(connection)
            } else {
                columns.clear()
            }
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
            results(connection)
        }
        .onChange(of: data.fields, initial: true) { _, _ in
            synchronizeColumns(connection)
        }
        .onChange(of: data.selectedObject) { _, _ in
            synchronizeColumns(connection)
        }
    }

    private func controls(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            modePicker(connection)
            if !compact {
                commandSeparator
                objectControls(connection)
            }
            Spacer(minLength: UIScale.pt(6))
            connectionActions(connection)
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(height: UIScale.pt(44))
        .background(palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.line.opacity(0.72))
                .frame(height: 1)
        }
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
                if !compact {
                    Label(selectedObjectTitle, systemImage: selectedObjectSymbol)
                        .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                        .lineLimit(1)
                }
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
        HStack(spacing: UIScale.pt(2)) {
            ForEach(DatabaseWorkbenchMode.allCases, id: \.self) { mode in
                Button {
                    workbenchModeBinding(connection).wrappedValue = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .foregroundStyle(
                            workbenchMode == mode ? palette.ink : palette.inkSoft
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: UIScale.pt(24))
                        .background(
                            workbenchMode == mode
                                ? palette.ink.opacity(dark ? 0.14 : 0.075) : .clear,
                            in: RoundedRectangle(cornerRadius: UIScale.pt(5)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(workbenchMode == mode ? .isSelected : [])
            }
        }
        .padding(UIScale.pt(2))
        .frame(width: UIScale.pt(118))
        .background(palette.canvas.opacity(0.76), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .strokeBorder(palette.line.opacity(0.72), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace mode")
    }

    private func connectionActions(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(6)) {
            connectionPolicy(connection)
            Button {
                data.browse(connection)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(
                DatabaseCommandButtonStyle(
                    kind: .utility, dark: dark, palette: palette)
            )
            .disabled(data.isLoading || explorer.selectedObject == nil)
            .help("Refresh data")
            .accessibilityLabel("Refresh selected object")
            if canInsertData(connection) {
                Button {
                    data.beginInsert(connection)
                } label: {
                    Label(newItemTitle(connection), systemImage: "plus")
                }
                .buttonStyle(
                    DatabaseCommandButtonStyle(
                        kind: .primary, dark: dark, palette: palette)
                )
                .disabled(
                    (data.fields.isEmpty && !usesDocumentEditor(connection))
                        || mutations.hasTrackedMutation
                )
                .help(newItemHelp(connection))
            }
            Menu {
                Button {
                    data.cancel()
                    Task { await connections.disconnectSelected() }
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .frame(width: UIScale.pt(30), height: UIScale.pt(30))
                    .foregroundStyle(palette.inkSoft)
                    .background(
                        palette.canvas.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(7))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(7))
                            .strokeBorder(palette.line.opacity(0.68), lineWidth: 1)
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More database actions")
            .accessibilityLabel("More database actions")
        }
    }

    @ViewBuilder
    private func connectionPolicy(_ connection: DatabaseConnectionSummary) -> some View {
        if connection.environmentKind == .production {
            Label("Production", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .foregroundStyle(DashSkin.warn)
                .help("Production connection")
                .accessibilityLabel("Production connection")
        } else if connection.readOnlyPolicy != .disabled {
            Label("Read only", systemImage: "lock.fill")
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .foregroundStyle(palette.inkFaint)
                .help("Read-only connection")
                .accessibilityLabel("Read-only connection")
        } else if !hasAnyDataMutation(connection) {
            Label("Browse only", systemImage: "eye")
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .foregroundStyle(palette.inkFaint)
                .help(mutationUnavailableHelp(connection))
                .accessibilityLabel("Browse-only connection")
        }
    }

    private func objectControls(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            Image(systemName: selectedObjectSymbol)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(theme)
                .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                .background(theme.opacity(0.12), in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(selectedObjectTitle)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                if let selected = explorer.selectedObject, selected.path.count > 1 {
                    Text(selected.path.dropLast().joined(separator: " / "))
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(palette.inkFaint)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: UIScale.pt(220), alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var commandSeparator: some View {
        Rectangle()
            .fill(palette.line.opacity(0.72))
            .frame(width: 1, height: UIScale.pt(18))
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
                HStack(spacing: UIScale.pt(7)) {
                    Image(systemName: selectedObjectSymbol)
                        .font(.system(size: UIScale.pt(11), weight: .semibold))
                        .foregroundStyle(theme)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(selectedObjectTitle)
                            .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: UIScale.pt(7), weight: .bold))
                        .foregroundStyle(palette.inkFaint)
                }
                .padding(.horizontal, UIScale.pt(8))
                .frame(height: UIScale.pt(32))
                .background(
                    palette.canvas.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(7))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(7))
                        .strokeBorder(palette.line.opacity(0.68), lineWidth: 1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(explorer.groups.isEmpty)
            if let context = selectedObjectContext {
                Text(context)
                    .font(.system(size: UIScale.pt(9.5)))
                    .foregroundStyle(palette.inkFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                explorer.load(connection, force: true)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(
                DatabaseCommandButtonStyle(
                    kind: .utility, dark: dark, palette: palette)
            )
            .help("Reload database objects")
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
                    GeometryReader { proxy in
                        let inspectorWidth = UIScale.pt(300)
                        let splitThreshold = UIScale.pt(780) + 1
                        if proxy.size.width >= splitThreshold {
                            let gridWidth = proxy.size.width - inspectorWidth - 1
                            HStack(spacing: 0) {
                                grid(connection)
                                    .frame(width: gridWidth)
                                Divider().opacity(0.35)
                                inspectorRegion(connection).frame(width: inspectorWidth)
                            }
                        } else {
                            VStack(spacing: 0) {
                                grid(connection)
                                Divider().opacity(0.35)
                                inspectorRegion(connection).frame(maxHeight: UIScale.pt(260))
                            }
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
            if workbenchMode == .browse {
                DatabaseFilterRibbon(
                    data: data,
                    connection: connection,
                    columns: columns,
                    accent: theme,
                    palette: palette,
                    apply: { data.browse(connection) })
            }
            DatabaseNativeTableView(
                accent: theme,
                background: palette.canvas,
                grid: palette.grid,
                ink: palette.ink,
                inkFaint: palette.inkFaint,
                fields: displayedFields(connection),
                records: data.records,
                selectedIndex: data.selectedRecordIndex,
                sorts: tableSorts,
                nextContinuation: data.nextContinuation,
                isLoading: data.isLoading,
                columnWidth: { columns.width(for: $0) },
                text: { data.text(for: $0) },
                loadMore: { data.loadNextPage(connection) },
                select: { data.selectRecord(at: $0) },
                open: { index in
                    if data.selectedRecordIndex != index {
                        data.selectRecord(at: index)
                    }
                    if workbenchMode == .browse,
                        canUpdateData(connection),
                        data.canMutateSelectedRecord(.update, connection: connection)
                    {
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
                },
                resizeColumn: { field, width in
                    columns.setWidth(width, for: field)
                }
            )
            .clipped()
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
            HStack(spacing: UIScale.pt(8)) {
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
                if showsSelectedRecordEditAction(connection) {
                    Button {
                        data.beginEditingSelectedRow(connection)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(
                        DatabaseInspectorActionButtonStyle(
                            kind: .neutral, palette: palette)
                    )
                    .disabled(mutations.hasTrackedMutation)
                    .help(editorTitle(connection))
                    .accessibilityLabel(editorTitle(connection))
                }
                if showsSelectedRecordDeleteAction(connection) {
                    Button(role: .destructive) {
                        requestDelete(connection)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(
                        DatabaseInspectorActionButtonStyle(
                            kind: .danger, palette: palette)
                    )
                    .disabled(mutations.hasTrackedMutation)
                    .help(deleteTitle(connection))
                    .accessibilityLabel(deleteTitle(connection))
                    .accessibilityHint("Opens a safety review before deletion")
                }
                if showsSelectedRecordEditAction(connection)
                    || showsSelectedRecordDeleteAction(connection)
                {
                    Rectangle()
                        .fill(palette.line.opacity(0.72))
                        .frame(width: 1, height: UIScale.pt(16))
                        .padding(.horizontal, UIScale.pt(2))
                }
                Button {
                    if let index = data.selectedRecordIndex { data.selectRecord(at: index) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(
                    DatabaseInspectorActionButtonStyle(
                        kind: .neutral, palette: palette)
                )
                .keyboardShortcut(.cancelAction)
                .help(closeDetailTitle(connection))
                .accessibilityLabel(closeDetailTitle(connection))
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(38))
            Divider().opacity(0.35)
            if usesDocumentEditor(connection) {
                documentMetadata(record)
            }
            ScrollView {
                if usesDocumentEditor(connection) {
                    documentInspector(record)
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

    @ViewBuilder
    private func documentMetadata(_ record: DatabaseRecord) -> some View {
        let metadata = documentMetadataComponents(record)
        if !metadata.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(6)) {
                    ForEach(Array(metadata.enumerated()), id: \.offset) { _, component in
                        HStack(spacing: UIScale.pt(4)) {
                            Text(component.name)
                                .foregroundStyle(.secondary)
                            Text(data.text(for: component.value))
                                .textSelection(.enabled)
                        }
                        .font(.system(size: UIScale.pt(9.5), design: .monospaced))
                        .padding(.horizontal, UIScale.pt(7))
                        .padding(.vertical, UIScale.pt(4))
                        .background(palette.canvas)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, UIScale.pt(12))
                .padding(.vertical, UIScale.pt(8))
            }
            Divider().opacity(0.35)
        }
    }

    @ViewBuilder
    private func documentInspector(_ record: DatabaseRecord) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            if documentPresentation == .source {
                if let source = data.documentSource(record) {
                    Text(source)
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Source view is unavailable for one or more unsupported values.")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                }
            } else {
                DatabaseDocumentOutline(
                    nodes: DatabaseDocumentNode.fields(documentSourceFields(record)),
                    text: { data.text(for: $0) })
            }
            if let highlight = documentHighlight(record) {
                Divider().opacity(0.35)
                Text("Highlights")
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(.secondary)
                DatabaseDocumentOutline(
                    nodes: DatabaseDocumentNode.value(highlight, name: "matches"),
                    text: { data.text(for: $0) })
            }
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func documentSourceFields(_ record: DatabaseRecord) -> [DatabaseObjectField] {
        record.fields.filter { $0.name != "_highlight" }
    }

    private func documentHighlight(_ record: DatabaseRecord) -> DatabaseValue? {
        record.fields.first(where: { $0.name == "_highlight" })?.value
    }

    private func documentMetadataComponents(
        _ record: DatabaseRecord
    ) -> [DatabaseIdentityComponent] {
        guard record.identity?.kind == .searchDocument else { return [] }
        return (record.identity?.components ?? []) + (record.identity?.concurrencyTokens ?? [])
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

    private func showsSelectedRecordEditAction(
        _ connection: DatabaseConnectionSummary
    ) -> Bool {
        workbenchMode == .browse
            && canUpdateData(connection)
            && data.canMutateSelectedRecord(.update, connection: connection)
    }

    private func showsSelectedRecordDeleteAction(
        _ connection: DatabaseConnectionSummary
    ) -> Bool {
        workbenchMode == .browse
            && canDeleteData(connection)
            && data.canMutateSelectedRecord(.delete, connection: connection)
    }

    private func deleteTitle(_ connection: DatabaseConnectionSummary) -> String {
        if connection.product.family == .keyValue { return "Delete key" }
        if usesDocumentEditor(connection) { return "Delete document" }
        return "Delete row"
    }

    private func closeDetailTitle(_ connection: DatabaseConnectionSummary) -> String {
        if connection.product.family == .keyValue { return "Close key details" }
        if usesDocumentEditor(connection) { return "Close document details" }
        return "Close row details"
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
        data.supportsDataMutation(capability, connection: connection)
            && selectedObjectAllowsMutation(connection)
            && connections.selectedConnectionSupports(capability)
    }

    private func selectedObjectAllowsMutation(
        _ connection: DatabaseConnectionSummary
    ) -> Bool {
        guard let kind = explorer.selectedObject?.kind else { return false }
        return switch connection.product.family {
        case .relational, .analytical: kind == .table
        case .keyValue: kind == .keyspace
        case .document: kind == .collection
        case .search: kind == .index
        }
    }

    private func synchronizeColumns(_ connection: DatabaseConnectionSummary) {
        guard let object = data.selectedObject else {
            columns.clear()
            return
        }
        columns.synchronize(
            connectionID: connection.id,
            object: object,
            fields: data.fields)
    }

    private func displayedFields(
        _ connection: DatabaseConnectionSummary
    ) -> [DatabaseFieldDescriptor] {
        guard columns.connectionID == connection.id,
            columns.object == data.selectedObject,
            !columns.columns.isEmpty
        else { return data.fields }
        return columns.visibleFields
    }

    private func mutationUnavailableHelp(_ connection: DatabaseConnectionSummary) -> String {
        if connection.readOnlyPolicy != .disabled
            || connection.environmentProtection == .readOnly
            || connection.productionPolicy == .prohibitMutations
        {
            return "This connection policy allows browsing only."
        }
        if !selectedObjectAllowsMutation(connection) {
            return "The selected object is read-only."
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

    private var selectedObjectContext: String? {
        guard let selected = explorer.selectedObject, selected.path.count > 1 else { return nil }
        return selected.path.dropLast().joined(separator: " / ")
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

private struct DatabaseInspectorActionButtonStyle: ButtonStyle {
    enum Kind {
        case neutral
        case danger
    }

    let kind: Kind
    let palette: DatabaseThemePalette

    func makeBody(configuration: Configuration) -> some View {
        DatabaseInspectorActionButtonBody(
            label: configuration.label,
            kind: kind,
            palette: palette,
            pressed: configuration.isPressed)
    }
}

private struct DatabaseInspectorActionButtonBody<Label: View>: View {
    let label: Label
    let kind: DatabaseInspectorActionButtonStyle.Kind
    let palette: DatabaseThemePalette
    let pressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: UIScale.pt(12), weight: .medium))
            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(6))
                    .strokeBorder(focused ? palette.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.38)
            .brightness(pressed && enabled ? -0.08 : 0)
            .onHover { hovering = enabled && $0 }
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion),
                value: hovering
            )
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion),
                value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .neutral:
            hovering ? palette.ink : palette.inkSoft
        case .danger:
            DashSkin.danger.opacity(hovering ? 1 : 0.82)
        }
    }

    private var background: Color {
        switch kind {
        case .neutral:
            palette.line.opacity(pressed ? 0.72 : hovering ? 0.52 : 0)
        case .danger:
            DashSkin.danger.opacity(pressed ? 0.22 : hovering ? 0.12 : 0)
        }
    }
}

private struct DatabaseCommandButtonStyle: ButtonStyle {
    enum Kind {
        case utility
        case primary
    }

    let kind: Kind
    let dark: Bool
    let palette: DatabaseThemePalette

    func makeBody(configuration: Configuration) -> some View {
        DatabaseCommandButtonBody(
            label: configuration.label,
            kind: kind,
            dark: dark,
            palette: palette,
            pressed: configuration.isPressed)
    }
}

private struct DatabaseCommandButtonBody<Label: View>: View {
    let label: Label
    let kind: DatabaseCommandButtonStyle.Kind
    let dark: Bool
    let palette: DatabaseThemePalette
    let pressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: UIScale.pt(10.5), weight: .semibold))
            .padding(.horizontal, kind == .primary ? UIScale.pt(10) : 0)
            .frame(minWidth: UIScale.pt(30))
            .frame(height: UIScale.pt(30))
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .strokeBorder(border, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.42)
            .brightness(pressed && enabled ? -0.08 : 0)
            .onHover { hovering = enabled && $0 }
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion),
                value: hovering
            )
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion),
                value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            dark ? palette.canvas : .white
        case .utility:
            hovering ? palette.ink : palette.inkSoft
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            DashSkin.accentDeep(dark)
        case .utility:
            hovering ? palette.line.opacity(0.72) : palette.canvas.opacity(0.72)
        }
    }

    private var border: Color {
        switch kind {
        case .primary:
            dark ? palette.ink.opacity(0.12) : Color.white.opacity(0.28)
        case .utility:
            palette.line.opacity(hovering ? 0.92 : 0.68)
        }
    }
}

private struct DatabaseDocumentNode: Identifiable {
    let id: String
    let name: String
    let value: DatabaseValue
    let children: [DatabaseDocumentNode]?

    static func fields(
        _ fields: [DatabaseObjectField],
        prefix: String = "root"
    ) -> [DatabaseDocumentNode] {
        fields.enumerated().map { index, field in
            node(
                value: field.value,
                name: field.name,
                id: "\(prefix).\(index).\(field.name)")
        }
    }

    static func value(_ value: DatabaseValue, name: String) -> [DatabaseDocumentNode] {
        [node(value: value, name: name, id: "root.\(name)")]
    }

    private static func node(
        value: DatabaseValue,
        name: String,
        id: String
    ) -> DatabaseDocumentNode {
        let children: [DatabaseDocumentNode]?
        switch value {
        case .object(let fields):
            children = Self.fields(fields, prefix: id)
        case .array(let values):
            children = values.enumerated().map { index, child in
                node(value: child, name: "[\(index)]", id: "\(id).\(index)")
            }
        default:
            children = nil
        }
        return DatabaseDocumentNode(id: id, name: name, value: value, children: children)
    }

    var collectionSummary: String? {
        switch value {
        case .object(let fields): "{\(fields.count) fields}"
        case .array(let values): "[\(values.count) values]"
        default: nil
        }
    }
}

private struct DatabaseDocumentOutline: View {
    let nodes: [DatabaseDocumentNode]
    let text: (DatabaseValue) -> String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: UIScale.pt(7)) {
            OutlineGroup(nodes, children: \.children) { node in
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                    Text(node.name)
                        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: UIScale.pt(8))
                    Text(node.collectionSummary ?? text(node.value))
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .foregroundStyle(node.collectionSummary == nil ? .primary : .secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
