import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseWorkbenchView: View {
    let connections: DatabaseConnectionWorkspaceModel
    let data: DatabaseDataWorkspaceModel
    let mutations: DatabaseWorkspaceModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

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
        .background(DashSkin.paper(dark))
        .task(id: connections.selectedConnectionID) {
            data.prepare(for: connections.selectedConnection)
        }
    }

    @ViewBuilder
    private func sessionContent(_ connection: DatabaseConnectionSummary) -> some View {
        switch connections.selectedSessionState {
        case .disconnected:
            VStack(spacing: UIScale.pt(16)) {
                Image(systemName: productSymbol(connection.product))
                    .font(.system(size: UIScale.pt(40), weight: .light))
                    .foregroundStyle(DashSkin.accent(dark))
                Text(connection.name)
                    .font(.system(size: UIScale.pt(21), weight: .semibold))
                Text("\(connection.product.displayName) · \(connection.environmentLabel)")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Button("Connect") {
                    Task { await connections.connectSelected() }
                }
                .buttonStyle(.edith(.primary, tint: DashSkin.accent(dark)))
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connecting:
            workingState("Connecting", "Opening a secure database session.")
        case .connected:
            workspace(connection)
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
            contextRail(connection)
            Divider().opacity(0.35)
            controls(connection)
            Divider().opacity(0.35)
            results(connection)
        }
    }

    private func contextRail(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: productSymbol(connection.product))
                .foregroundStyle(DashSkin.accent(dark))
            Text(connection.name)
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .lineLimit(1)
            Text(connection.product.displayName)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
            Spacer(minLength: UIScale.pt(8))
            if connection.environmentKind == .production {
                Label("Production", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(DashSkin.warn)
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
            } else if connection.readOnlyPolicy != .disabled {
                Label("Read only", systemImage: "lock.fill")
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
            }
            Button {
                data.cancel()
                Task { await connections.disconnectSelected() }
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.edith(.borderless))
            .help("Disconnect")
        }
        .padding(.horizontal, UIScale.pt(compact ? 10 : 14))
        .frame(height: UIScale.pt(40))
        .background(DashSkin.paper2(dark).opacity(0.7))
    }

    private func controls(_ connection: DatabaseConnectionSummary) -> some View {
        Group {
            if compact {
                VStack(spacing: UIScale.pt(8)) {
                    targetControls(connection)
                    filterControls(connection)
                }
            } else {
                HStack(spacing: UIScale.pt(8)) {
                    targetControls(connection)
                    Divider().frame(height: UIScale.pt(20))
                    filterControls(connection)
                }
            }
        }
        .padding(UIScale.pt(10))
    }

    private func targetControls(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            TextField(targetPlaceholder(connection), text: targetBinding)
                .textFieldStyle(.roundedBorder)
                .font(DashSkin.mono(11))
                .accessibilityLabel("Database object")
                .onSubmit { data.browse(connection) }
            Button {
                data.browse(connection)
            } label: {
                Label(data.records.isEmpty ? "Open" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.edith(.primary, tint: DashSkin.accent(dark)))
            .disabled(data.isLoading)
        }
        .frame(maxWidth: compact ? .infinity : UIScale.pt(390))
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
            emptyState(symbol: "tablecells", title: "Open an object", detail: guidance(connection))
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
                HStack(spacing: 0) {
                    grid(connection)
                    if data.editorMode != nil || data.selectedRecord != nil {
                        Divider().opacity(0.35)
                        inspectorRegion(connection).frame(width: UIScale.pt(320))
                    }
                }
            }
        }
    }

    private func grid(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(data.records.enumerated()), id: \.offset) { index, record in
                            row(record, index: index)
                        }
                    } header: {
                        header(connection)
                    }
                }
            }
            Divider().opacity(0.35)
            HStack(spacing: UIScale.pt(9)) {
                if data.isLoading { ProgressView().controlSize(.small) }
                Text(resultSummary)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer(minLength: 0)
                if data.supportsRowMutations(connection) {
                    Button {
                        data.beginInsert(connection)
                    } label: {
                        Label("New row", systemImage: "plus")
                    }
                    .buttonStyle(.edith(.secondary))
                    .disabled(data.fields.isEmpty || mutations.hasTrackedMutation)
                }
                if data.hasNextPage {
                    Button("Load more") { data.loadNextPage(connection) }
                        .buttonStyle(.edith(.secondary))
                        .disabled(data.isLoading)
                }
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(38))
            .background(DashSkin.paper2(dark).opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ connection: DatabaseConnectionSummary) -> some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: UIScale.pt(44), alignment: .trailing)
                .padding(.trailing, UIScale.pt(10))
            ForEach(data.fields, id: \.path) { field in
                Button {
                    guard field.isSortable else { return }
                    let name = field.path.segments.joined(separator: ".")
                    if data.sortField == name {
                        data.sortDirection =
                            data.sortDirection == .ascending ? .descending : .ascending
                    } else {
                        data.sortField = name
                        data.sortDirection = .ascending
                    }
                    data.browse(connection)
                } label: {
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        Text(field.displayName).foregroundStyle(DashSkin.ink(dark))
                        Text(field.typeName)
                            .font(.system(size: UIScale.pt(9.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    .frame(width: UIScale.pt(176), alignment: .leading)
                    .padding(.horizontal, UIScale.pt(10))
                }
                .buttonStyle(.plain)
                .disabled(!field.isSortable)
                Divider().opacity(0.25)
            }
        }
        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
        .frame(height: UIScale.pt(42))
        .background(DashSkin.paper2(dark))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func row(_ record: DatabaseRecord, index: Int) -> some View {
        Button {
            data.selectRecord(at: index)
        } label: {
            HStack(spacing: 0) {
                Text((index + 1).formatted())
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(44), alignment: .trailing)
                    .padding(.trailing, UIScale.pt(10))
                ForEach(data.fields, id: \.path) { field in
                    let name = field.path.segments.joined(separator: ".")
                    Text(data.text(for: data.value(named: name, in: record)))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                        .frame(width: UIScale.pt(176), alignment: .leading)
                        .padding(.horizontal, UIScale.pt(10))
                    Divider().opacity(0.18)
                }
            }
            .font(DashSkin.mono(10.5))
            .frame(height: UIScale.pt(34))
            .background(
                data.selectedRecordIndex == index
                    ? DashSkin.accent(dark).opacity(0.12)
                    : (index.isMultiple(of: 2)
                        ? DashSkin.paper(dark) : DashSkin.paper2(dark).opacity(0.34))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Row \(index + 1)")
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
                Text("Row details").font(.system(size: UIScale.pt(12.5), weight: .semibold))
                Spacer(minLength: 0)
                if data.supportsRowMutations(connection), record.identity != nil {
                    Button("Edit") {
                        data.beginEditingSelectedRow(connection)
                    }
                    .buttonStyle(.edith(.borderless))
                    .disabled(mutations.hasTrackedMutation)
                    Button {
                        requestDelete(connection)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(DashSkin.danger)
                    }
                    .buttonStyle(.edith(.borderless))
                    .disabled(mutations.hasTrackedMutation)
                    .accessibilityLabel("Delete row")
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
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Text(data.text(for: field.value))
                                .font(DashSkin.mono(11))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(UIScale.pt(12))
            }
        }
        .background(DashSkin.paper2(dark).opacity(0.45))
    }

    private func editor(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UIScale.pt(8)) {
                Text(editorTitle)
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                Spacer(minLength: 0)
                Button("Cancel") { data.cancelEditor() }
                    .buttonStyle(.edith(.borderless))
                Button("Review") { requestEditorMutation(connection) }
                    .buttonStyle(.edith(.primary, tint: DashSkin.accent(dark)))
                    .disabled(mutations.hasTrackedMutation)
            }
            .padding(UIScale.pt(12))
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(11)) {
                    if let error = data.editorError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(data.editorFields) { field in
                        editorField(field)
                    }
                }
                .padding(UIScale.pt(12))
            }
        }
        .background(DashSkin.paper2(dark).opacity(0.45))
    }

    private func editorField(_ field: DatabaseRowFieldDraft) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(6)) {
                Toggle("", isOn: editorIncludedBinding(field.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!field.isEditable)
                Text(field.id)
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(field.typeName)
                    .font(.system(size: UIScale.pt(9.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if field.isIdentity {
                    Label("key", systemImage: "key.fill")
                        .labelStyle(.titleOnly)
                        .font(.system(size: UIScale.pt(9.5), weight: .medium))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                } else if field.isEditable {
                    Button("NULL") { data.setEditorFieldNull(field.id) }
                        .buttonStyle(.edith(.borderless))
                        .font(.system(size: UIScale.pt(9.5), weight: .medium))
                }
            }
            TextField("Value", text: editorTextBinding(field.id))
                .textFieldStyle(.roundedBorder)
                .font(DashSkin.mono(10.5))
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
                .foregroundStyle(DashSkin.inkFaint(dark))
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
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(title).font(.system(size: UIScale.pt(17), weight: .semibold))
            Text(detail)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(410))
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.edith(.primary, tint: DashSkin.accent(dark)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(UIScale.pt(26))
    }

    private var targetBinding: Binding<String> {
        Binding(get: { data.targetText }, set: { data.targetText = $0 })
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

    private var editorTitle: String {
        switch data.editorMode {
        case .insert: "New row"
        case .update: "Edit row"
        case nil: "Row"
        }
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

    private func targetPlaceholder(_ connection: DatabaseConnectionSummary) -> String {
        switch connection.product {
        case .postgresql: "schema.table"
        case .sqlite: "table"
        case .mysql, .mariaDB: "database.table"
        case .redis, .valkey: "logical database"
        case .mongoDB: "database.collection"
        case .elasticsearch, .openSearch: "index"
        case .clickHouse: "database.table"
        }
    }

    private func guidance(_ connection: DatabaseConnectionSummary) -> String {
        switch connection.product {
        case .postgresql: "Enter a table such as public.customers."
        case .sqlite: "Enter a table such as customers."
        case .mysql, .mariaDB: "Enter a table such as app.customers."
        case .redis, .valkey: "Open the selected logical database to browse its keys."
        case .mongoDB: "Enter a collection such as app.customers."
        case .elasticsearch, .openSearch: "Enter an index such as products."
        case .clickHouse: "Enter a table such as default.events."
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
