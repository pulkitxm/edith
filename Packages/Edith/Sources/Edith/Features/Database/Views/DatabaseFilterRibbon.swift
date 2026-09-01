import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseFilterRibbon: View {
    let data: DatabaseDataWorkspaceModel
    let connection: DatabaseConnectionSummary
    let accent: Color
    let palette: DatabaseThemePalette
    let apply: () -> Void

    @State private var editorID: UUID?

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(7)) {
                    addFilterMenu
                    filterClauses
                    if !data.orderedSorts.isEmpty {
                        ribbonSeparator
                    }
                    addSortMenu
                    sortClauses
                }
                .padding(.vertical, UIScale.pt(6))
            }
            if data.hasActiveFilters || data.hasActiveSorts {
                Button {
                    data.clearFilters()
                    data.clearSorts()
                    apply()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.edith(.borderless))
                .foregroundStyle(palette.inkFaint)
                .help("Clear filters and sorting")
                .accessibilityLabel("Clear filters and sorting")
            }
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(minHeight: UIScale.pt(42))
        .background(palette.panel)
    }

    private var addFilterMenu: some View {
        Menu {
            ForEach(filterableFields, id: \.path) { field in
                Button(field.displayName) {
                    editorID = data.addFilterClause(
                        field: field.path.segments.joined(separator: "."))
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(filterableFields.isEmpty)
        .help(filterableFields.isEmpty ? "This result has no filterable fields" : "Add a filter")
    }

    @ViewBuilder
    private var filterClauses: some View {
        ForEach(Array(data.filterClauses.enumerated()), id: \.element.id) { index, clause in
            if index > 0 {
                conjunctionControl
            }
            filterChip(clause)
        }
    }

    private var conjunctionControl: some View {
        Menu {
            ForEach(DatabaseWorkspaceFilterConjunction.allCases, id: \.self) { conjunction in
                Button {
                    data.setFilterConjunction(conjunction)
                    apply()
                } label: {
                    if data.filterConjunction == conjunction {
                        Label(conjunction.title, systemImage: "checkmark")
                    } else {
                        Text(conjunction.title)
                    }
                }
            }
        } label: {
            Text(data.filterConjunction.title)
                .font(.system(size: UIScale.pt(8.5), weight: .bold))
                .foregroundStyle(palette.inkFaint)
                .padding(.horizontal, UIScale.pt(2))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Match all filters or any filter")
    }

    private func filterChip(_ clause: DatabaseWorkspaceFilterClause) -> some View {
        Button {
            editorID = clause.id
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: clause.isEnabled ? "line.3.horizontal.decrease" : "pause.fill")
                    .font(.system(size: UIScale.pt(8.5), weight: .semibold))
                Text(clause.summary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: UIScale.pt(7.5), weight: .bold))
            }
            .font(.system(size: UIScale.pt(10.5), weight: .medium))
            .foregroundStyle(clause.isEnabled ? palette.ink : palette.inkFaint)
            .padding(.horizontal, UIScale.pt(8))
            .frame(height: UIScale.pt(26))
            .background(
                clause.isEnabled ? accent.opacity(0.12) : palette.canvas,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        clause.isEnabled ? accent.opacity(0.32) : palette.line.opacity(0.55),
                        lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(clause.summary)
        .popover(isPresented: editorPresentation(clause.id), arrowEdge: .bottom) {
            filterEditor(clause.id)
        }
    }

    private var addSortMenu: some View {
        Menu {
            ForEach(sortableFields, id: \.path) { field in
                Menu(field.displayName) {
                    Button("Ascending") {
                        setSort(field, direction: .ascending)
                    }
                    Button("Descending") {
                        setSort(field, direction: .descending)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(sortableFields.isEmpty)
        .help(sortableFields.isEmpty ? "This result has no sortable fields" : "Add sorting")
    }

    @ViewBuilder
    private var sortClauses: some View {
        ForEach(Array(data.orderedSorts.enumerated()), id: \.element.id) { index, sort in
            sortChip(sort, priority: index)
        }
    }

    private func sortChip(_ sort: DatabaseWorkspaceSort, priority: Int) -> some View {
        Menu {
            Button("Ascending") {
                data.setSort(field: sort.field, direction: .ascending, additive: true)
                apply()
            }
            Button("Descending") {
                data.setSort(field: sort.field, direction: .descending, additive: true)
                apply()
            }
            Divider()
            Button("Move earlier") {
                data.moveSort(field: sort.field, to: priority - 1)
                apply()
            }
            .disabled(priority == 0)
            Button("Move later") {
                data.moveSort(field: sort.field, to: priority + 1)
                apply()
            }
            .disabled(priority == data.orderedSorts.count - 1)
            Button("Remove sort") {
                data.removeSort(field: sort.field)
                apply()
            }
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                Text((priority + 1).formatted())
                    .font(.system(size: UIScale.pt(8), weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                    .background(accent.opacity(0.13), in: Circle())
                Text(sort.field)
                    .lineLimit(1)
                Image(
                    systemName: sort.direction == .ascending
                        ? "arrow.up" : "arrow.down"
                )
                .font(.system(size: UIScale.pt(8.5), weight: .bold))
            }
            .font(.system(size: UIScale.pt(10.5), weight: .medium))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, UIScale.pt(7))
            .frame(height: UIScale.pt(26))
            .background(palette.canvas, in: Capsule())
            .overlay {
                Capsule().stroke(palette.line.opacity(0.55), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort priority \(priority + 1): \(sort.summary)")
    }

    private var ribbonSeparator: some View {
        Rectangle()
            .fill(palette.line.opacity(0.55))
            .frame(width: 1, height: UIScale.pt(18))
            .padding(.horizontal, UIScale.pt(2))
    }

    @ViewBuilder
    private func filterEditor(_ id: UUID) -> some View {
        if let clause = data.filterClauses.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                HStack(spacing: UIScale.pt(8)) {
                    Text("Filter")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    Spacer(minLength: 0)
                    Toggle("Enabled", isOn: clauseEnabledBinding(id))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                filterEditorControl("Field") {
                    Picker("Field", selection: clauseFieldBinding(id)) {
                        ForEach(filterableFields, id: \.path) { field in
                            Text(field.displayName)
                                .tag(field.path.segments.joined(separator: "."))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                filterEditorControl("Condition") {
                    Picker("Condition", selection: clauseOperationBinding(id)) {
                        ForEach(operators(for: clause), id: \.self) { operation in
                            Text(operatorTitle(operation)).tag(operation)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if operationNeedsValue(clause.operation) {
                    filterEditorControl("Value") {
                        TextField(valuePlaceholder(clause.operation), text: clauseValueBinding(id))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: UIScale.pt(11), design: .monospaced))
                            .onSubmit {
                                editorID = nil
                                apply()
                            }
                    }
                }
                if operationSupportsCaseSensitivity(clause.operation) {
                    filterEditorControl("Text matching") {
                        Picker("Text matching", selection: clauseSensitivityBinding(id)) {
                            Text("Database default")
                                .tag(DatabaseFilterCaseSensitivity.productDefault)
                            Text("Case sensitive").tag(DatabaseFilterCaseSensitivity.sensitive)
                            Text("Ignore case").tag(DatabaseFilterCaseSensitivity.insensitive)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                HStack(spacing: UIScale.pt(8)) {
                    Button("Remove") {
                        editorID = nil
                        data.removeFilterClause(id: id)
                        apply()
                    }
                    .buttonStyle(.edith(.borderless))
                    .foregroundStyle(DashSkin.danger)
                    Spacer(minLength: 0)
                    Button("Apply filters") {
                        editorID = nil
                        apply()
                    }
                    .buttonStyle(.edith(.primary, tint: accent))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(UIScale.pt(14))
            .frame(width: UIScale.pt(330))
        }
    }

    private func filterEditorControl<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            Text(title)
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .foregroundStyle(palette.inkFaint)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filterableFields: [DatabaseFieldDescriptor] {
        data.fields.filter(\.isFilterable)
    }

    private var sortableFields: [DatabaseFieldDescriptor] {
        data.fields.filter(\.isSortable)
    }

    private func editorPresentation(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { editorID == id },
            set: { presented in
                if presented {
                    editorID = id
                } else if editorID == id {
                    editorID = nil
                }
            })
    }

    private func clauseFieldBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { clause(id)?.field ?? "" },
            set: { field in
                updateClause(id) { clause in
                    clause.field = field
                    if let descriptor = data.fields.first(where: {
                        $0.path.segments.joined(separator: ".") == field
                    }) {
                        clause.operation = data.defaultFilterOperator(for: descriptor)
                    }
                }
            })
    }

    private func clauseOperationBinding(_ id: UUID) -> Binding<DatabaseFilterOperator> {
        Binding(
            get: { clause(id)?.operation ?? .equal },
            set: { operation in
                updateClause(id) { clause in
                    clause.operation = operation
                    clause.caseSensitivity = defaultSensitivity(operation)
                }
            })
    }

    private func clauseValueBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { clause(id)?.valueText ?? "" },
            set: { value in
                updateClause(id) { $0.valueText = value }
            })
    }

    private func clauseEnabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { clause(id)?.isEnabled ?? false },
            set: { enabled in
                updateClause(id) { $0.isEnabled = enabled }
            })
    }

    private func clauseSensitivityBinding(
        _ id: UUID
    ) -> Binding<DatabaseFilterCaseSensitivity> {
        Binding(
            get: { clause(id)?.caseSensitivity ?? .productDefault },
            set: { sensitivity in
                updateClause(id) { $0.caseSensitivity = sensitivity }
            })
    }

    private func clause(_ id: UUID) -> DatabaseWorkspaceFilterClause? {
        data.filterClauses.first { $0.id == id }
    }

    private func updateClause(
        _ id: UUID,
        _ update: (inout DatabaseWorkspaceFilterClause) -> Void
    ) {
        guard var clause = clause(id) else { return }
        update(&clause)
        data.updateFilterClause(clause)
    }

    private func setSort(
        _ field: DatabaseFieldDescriptor,
        direction: DatabaseSortDirection
    ) {
        data.setSort(
            field: field.path.segments.joined(separator: "."),
            direction: direction,
            additive: !data.orderedSorts.isEmpty)
        apply()
    }

    private func operators(
        for clause: DatabaseWorkspaceFilterClause
    ) -> [DatabaseFilterOperator] {
        let typeName =
            data.fields.first {
                $0.path.segments.joined(separator: ".") == clause.field
            }?.typeName.lowercased() ?? "text"
        var options: [DatabaseFilterOperator]
        if typeName.contains("char") || typeName.contains("text")
            || typeName.contains("string") || typeName.contains("uuid")
        {
            options = [
                .contains, .equal, .notEqual, .startsWith, .endsWith, .in, .notIn,
            ]
            if connection.product.family == .search || connection.product == .clickHouse {
                options += [.regularExpression, .fullText]
            }
        } else if typeName.contains("bool") {
            options = [.equal, .notEqual]
        } else {
            options = [
                .equal, .notEqual, .greaterThan, .greaterThanOrEqual, .lessThan,
                .lessThanOrEqual, .between, .in, .notIn,
            ]
        }
        switch connection.product.family {
        case .relational:
            options += [.isNull, .isNotNull]
        case .document, .search, .analytical:
            options += [.isNull, .isNotNull, .isMissing, .isNotMissing]
        case .keyValue:
            break
        }
        if !options.contains(clause.operation) {
            options.insert(clause.operation, at: 0)
        }
        return options
    }

    private func operatorTitle(_ operation: DatabaseFilterOperator) -> String {
        switch operation {
        case .equal: "Is"
        case .notEqual: "Is not"
        case .greaterThan: "Greater than"
        case .greaterThanOrEqual: "At least"
        case .lessThan: "Less than"
        case .lessThanOrEqual: "At most"
        case .contains: "Contains"
        case .startsWith: "Starts with"
        case .endsWith: "Ends with"
        case .in: "In list"
        case .notIn: "Not in list"
        case .between: "Between"
        case .isNull: "Is null"
        case .isNotNull: "Is not null"
        case .isMissing: "Is missing"
        case .isNotMissing: "Is present"
        case .regularExpression: "Matches pattern"
        case .fullText: "Full-text match"
        }
    }

    private func operationNeedsValue(_ operation: DatabaseFilterOperator) -> Bool {
        switch operation {
        case .isNull, .isNotNull, .isMissing, .isNotMissing:
            false
        default:
            true
        }
    }

    private func operationSupportsCaseSensitivity(_ operation: DatabaseFilterOperator) -> Bool {
        switch operation {
        case .contains, .startsWith, .endsWith, .regularExpression, .fullText:
            true
        default:
            false
        }
    }

    private func defaultSensitivity(
        _ operation: DatabaseFilterOperator
    ) -> DatabaseFilterCaseSensitivity {
        switch operation {
        case .contains, .startsWith, .endsWith:
            .insensitive
        default:
            .productDefault
        }
    }

    private func valuePlaceholder(_ operation: DatabaseFilterOperator) -> String {
        switch operation {
        case .between: "Lower value, upper value"
        case .in, .notIn: "Value, value"
        case .regularExpression: "Pattern"
        case .fullText: "Search text"
        default: "Value"
        }
    }
}
