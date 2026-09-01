import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseFilterRibbon: View {
    let data: DatabaseDataWorkspaceModel
    let connection: DatabaseConnectionSummary
    let columns: DatabaseColumnsModel
    let accent: Color
    let palette: DatabaseThemePalette
    let apply: () -> Void

    @State private var editorID: UUID?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width < UIScale.pt(700) {
                    condensedRail
                } else {
                    expandedRail
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: UIScale.pt(38))
        .background(palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.line.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var expandedRail: some View {
        HStack(spacing: UIScale.pt(7)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(6)) {
                    addFilterMenu
                    filterClauses
                }
            }
            .layoutPriority(1)
            ribbonSeparator
            sortMenu
            columnsMenu
            clearControl
        }
        .padding(.horizontal, UIScale.pt(10))
    }

    private var condensedRail: some View {
        HStack(spacing: UIScale.pt(7)) {
            condensedFilterMenu
            sortMenu
            columnsMenu
            clearControl
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var clearControl: some View {
        if data.hasActiveFilters || data.hasActiveSorts {
            Button {
                data.clearFilters()
                data.clearSorts()
                apply()
            } label: {
                Text("Clear")
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(palette.inkFaint)
                    .frame(minWidth: UIScale.pt(28), minHeight: UIScale.pt(28))
            }
            .buttonStyle(.plain)
            .help("Clear filters and sorting")
            .accessibilityLabel("Clear filters and sorting")
        }
    }

    private var condensedFilterMenu: some View {
        Menu {
            if !data.filterClauses.isEmpty {
                Section("Current filters") {
                    ForEach(data.filterClauses) { clause in
                        Button(clause.summary) {
                            editorID = clause.id
                        }
                    }
                }
                Divider()
            }
            Section("Add filter") {
                ForEach(filterableFields, id: \.path) { field in
                    Button(field.displayName) {
                        editorID = data.addFilterClause(
                            field: field.path.segments.joined(separator: "."))
                    }
                }
            }
        } label: {
            railControlLabel(condensedFilterTitle, systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(filterableFields.isEmpty)
        .help(filterHelp)
        .accessibilityLabel(filterAccessibilityLabel)
    }

    private var columnsMenu: some View {
        Menu {
            Button("Show all") {
                columns.showAll()
            }
            .disabled(columns.allFieldsVisible)
            Button("Show first only") {
                columns.hideAll()
            }
            .disabled(columns.visibleCount <= 1)
            Divider()
            ForEach(Array(columns.columns.enumerated()), id: \.element.id) { index, column in
                Menu {
                    Button {
                        columns.toggleVisibility(column.id)
                    } label: {
                        if column.isVisible {
                            Label("Hide", systemImage: "eye.slash")
                        } else {
                            Label("Show", systemImage: "eye")
                        }
                    }
                    .disabled(column.isVisible && !columns.canHide(column.id))
                    Divider()
                    Button("Move earlier") {
                        columns.moveField(column.id, to: index - 1)
                    }
                    .disabled(index == 0)
                    Button("Move later") {
                        columns.moveField(column.id, to: index + 1)
                    }
                    .disabled(index == columns.columns.count - 1)
                } label: {
                    if column.isVisible {
                        Label(column.field.displayName, systemImage: "checkmark")
                    } else {
                        Text(column.field.displayName)
                    }
                }
            }
        } label: {
            railControlLabel("Columns", systemImage: "rectangle.split.3x1")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(columns.columns.isEmpty)
        .help("Choose and reorder visible columns")
        .accessibilityLabel(
            "Columns, \(columns.visibleCount) of \(columns.columns.count) visible")
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
            railControlLabel("Filter", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
                .font(.system(size: UIScale.pt(9), weight: .medium, design: .monospaced))
                .foregroundStyle(palette.inkFaint)
                .frame(minWidth: UIScale.pt(28), minHeight: UIScale.pt(28))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Match all filters or any filter")
    }

    private func filterChip(_ clause: DatabaseWorkspaceFilterClause) -> some View {
        Button {
            editorID = clause.id
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                if clause.isEnabled {
                    Circle()
                        .fill(accent)
                        .frame(width: UIScale.pt(5), height: UIScale.pt(5))
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: UIScale.pt(7.5), weight: .semibold))
                }
                Text(clause.field)
                    .font(.system(size: UIScale.pt(10), weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(operatorTitle(clause.operation))
                    .font(.system(size: UIScale.pt(9.5), weight: .medium))
                    .foregroundStyle(palette.inkFaint)
                    .lineLimit(1)
                if operationNeedsValue(clause.operation) {
                    Text(clause.valueText)
                        .font(.system(size: UIScale.pt(10), design: .monospaced))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: UIScale.pt(7), weight: .bold))
                    .foregroundStyle(palette.inkFaint)
            }
            .foregroundStyle(clause.isEnabled ? palette.ink : palette.inkFaint)
            .padding(.horizontal, UIScale.pt(7))
            .frame(height: UIScale.pt(28))
            .background(
                clause.isEnabled ? palette.canvas : palette.canvas.opacity(0.54),
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(6))
                    .strokeBorder(palette.line.opacity(0.72), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(clause.summary)
        .popover(isPresented: editorPresentation(clause.id), arrowEdge: .bottom) {
            filterEditor(clause.id)
        }
    }

    private var sortMenu: some View {
        Menu {
            if !data.orderedSorts.isEmpty {
                Section("Current sorting") {
                    ForEach(Array(data.orderedSorts.enumerated()), id: \.element.id) {
                        priority, sort in
                        Menu(sortMenuItemTitle(sort, priority: priority)) {
                            Button("Ascending") {
                                data.setSort(
                                    field: sort.field, direction: .ascending, additive: true)
                                apply()
                            }
                            Button("Descending") {
                                data.setSort(
                                    field: sort.field, direction: .descending, additive: true)
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
                        }
                    }
                }
                Divider()
            }
            Section("Add sort") {
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
            }
        } label: {
            railControlLabel(sortMenuTitle, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(sortableFields.isEmpty)
        .help(sortHelp)
        .accessibilityLabel(sortAccessibilityLabel)
    }

    private var ribbonSeparator: some View {
        Rectangle()
            .fill(palette.line.opacity(0.72))
            .frame(width: 1, height: UIScale.pt(18))
    }

    private func railControlLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: UIScale.pt(10), weight: .medium))
            .foregroundStyle(palette.inkSoft)
            .lineLimit(1)
            .padding(.horizontal, UIScale.pt(6))
            .frame(height: UIScale.pt(28))
            .background(
                palette.canvas.opacity(0.72), in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(6))
                    .strokeBorder(palette.line.opacity(0.68), lineWidth: 1)
            }
    }

    private var condensedFilterTitle: String {
        guard let first = data.filterClauses.first else { return "Filter" }
        let summary =
            first.summary.count > 28
            ? "\(first.summary.prefix(27))…" : first.summary
        let more = data.filterClauses.count > 1 ? " +\(data.filterClauses.count - 1)" : ""
        return "\(summary)\(more)"
    }

    private var filterHelp: String {
        guard !data.filterClauses.isEmpty else {
            return filterableFields.isEmpty
                ? "This result has no filterable fields" : "Add a filter"
        }
        return data.filterClauses.map(\.summary).joined(separator: ", ")
    }

    private var filterAccessibilityLabel: String {
        guard !data.filterClauses.isEmpty else { return "Filter, none active" }
        return "Filters, \(data.filterClauses.count) configured. \(filterHelp)"
    }

    private var sortMenuTitle: String {
        guard let first = data.orderedSorts.first else { return "Sort" }
        let direction = first.direction == .ascending ? "↑" : "↓"
        let more = data.orderedSorts.count > 1 ? " +\(data.orderedSorts.count - 1)" : ""
        return "\(sortFieldTitle(first.field)) \(direction)\(more)"
    }

    private var sortHelp: String {
        guard !data.orderedSorts.isEmpty else {
            return sortableFields.isEmpty ? "This result has no sortable fields" : "Add sorting"
        }
        return data.orderedSorts.enumerated().map {
            "\($0.offset + 1). \($0.element.summary)"
        }.joined(separator: ", ")
    }

    private var sortAccessibilityLabel: String {
        guard !data.orderedSorts.isEmpty else { return "Sort, none active" }
        return "Sort, \(data.orderedSorts.count) active. \(sortHelp)"
    }

    private func sortMenuItemTitle(
        _ sort: DatabaseWorkspaceSort,
        priority: Int
    ) -> String {
        let direction = sort.direction == .ascending ? "Ascending" : "Descending"
        return "\(priority + 1). \(sortFieldTitle(sort.field)), \(direction)"
    }

    private func sortFieldTitle(_ path: String) -> String {
        data.fields.first {
            $0.path.segments.joined(separator: ".") == path
        }?.displayName ?? path
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
                if connection.product.family != .keyValue,
                    operationSupportsCaseSensitivity(clause.operation)
                {
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
                    clause.caseSensitivity =
                        connection.product.family == .keyValue
                        ? .productDefault : defaultSensitivity(operation)
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
        if connection.product.family == .keyValue {
            return typeName == "redis-type"
                ? [.equal]
                : [.equal, .contains, .startsWith, .endsWith]
        }
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
