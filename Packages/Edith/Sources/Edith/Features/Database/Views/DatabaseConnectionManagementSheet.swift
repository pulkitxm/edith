import EdithDatabase
import EdithKit
import SwiftUI

enum DatabaseConnectionManagementPresentation: String, Identifiable {
    case edit
    case rename
    case duplicate

    var id: String { rawValue }
}

struct DatabaseConnectionManagementSheet: View {
    let connection: DatabaseConnectionSummary
    let model: DatabaseConnectionManagementModel
    let presentation: DatabaseConnectionManagementPresentation
    let edited: (DatabaseConnectionDefinition) -> Void
    let renamed: (DatabaseConnectionDefinition) -> Void
    let duplicated: (DatabaseConnectionDuplicateResult) -> Void
    let uncertain: (DatabaseConnectionManagementUncertainOutcome) -> Void
    let cancel: () -> Void

    @State private var draft: DatabaseConnectionEditDraft?
    @State private var name: String
    @State private var submitting = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.databaseAppTheme) private var appTheme

    init(
        connection: DatabaseConnectionSummary,
        model: DatabaseConnectionManagementModel,
        presentation: DatabaseConnectionManagementPresentation,
        edited: @escaping (DatabaseConnectionDefinition) -> Void,
        renamed: @escaping (DatabaseConnectionDefinition) -> Void,
        duplicated: @escaping (DatabaseConnectionDuplicateResult) -> Void,
        uncertain: @escaping (DatabaseConnectionManagementUncertainOutcome) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.connection = connection
        self.model = model
        self.presentation = presentation
        self.edited = edited
        self.renamed = renamed
        self.duplicated = duplicated
        self.uncertain = uncertain
        self.cancel = cancel
        _name = State(
            initialValue: presentation == .duplicate
                ? "\(connection.name) copy"
                : connection.name)
    }

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }
    private var isBusy: Bool {
        model.isBusy || submitting
    }
    private var preventsDismissal: Bool {
        submitting || (model.isBusy && model.operation != .loadingEdit)
    }
    private var hasValidName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            presentationContent
            Divider().opacity(0.35)
            footer
        }
        .frame(
            minWidth: UIScale.pt(360),
            idealWidth: UIScale.pt(presentation == .edit ? 620 : 440),
            minHeight: UIScale.pt(presentation == .edit ? 540 : 300),
            idealHeight: UIScale.pt(presentation == .edit ? 680 : 360)
        )
        .background(palette.canvas)
        .interactiveDismissDisabled(preventsDismissal)
        .task(id: taskID) {
            await prepare()
        }
    }

    private var taskID: String {
        "\(presentation.rawValue):\(connection.id.rawValue.uuidString)"
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .fill(headerTint.opacity(0.13))
                Image(systemName: headerSymbol)
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
                    .foregroundStyle(headerTint)
            }
            .frame(width: UIScale.pt(38), height: UIScale.pt(38))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(headerTitle)
                    .font(.system(size: UIScale.pt(16), weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(headerDetail)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(palette.inkFaint)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.edith(.borderless))
                .disabled(preventsDismissal)
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(16))
        .background(palette.panel.opacity(0.55))
    }

    @ViewBuilder
    private var presentationContent: some View {
        switch presentation {
        case .edit:
            editContent
        case .rename:
            compactContent {
                nameField(label: "Connection name", placeholder: "Connection name")
            }
        case .duplicate:
            compactContent {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    nameField(label: "Name for the copy", placeholder: "Connection copy")
                    notice(
                        "This copy reuses saved credential references. Secret values are not copied.",
                        symbol: "key.horizontal",
                        tint: DashSkin.warn)
                }
            }
        }
    }

    private var editContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                connectionContext
                if let draft {
                    editSections(draft)
                } else if model.operation == .loadingEdit {
                    loadingEdit
                } else if model.failure == nil {
                    loadingEdit
                }
                failureNotice
            }
            .padding(UIScale.pt(22))
        }
    }

    private func compactContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            connectionContext
            content()
            failureNotice
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var connectionContext: some View {
        section("Connection", symbol: connection.product.managementSymbolName) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: UIScale.pt(18)) {
                    contextFact("Product", connection.product.displayName)
                    contextFact("Endpoint", endpointText)
                }
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    contextFact("Product", connection.product.displayName)
                    contextFact("Endpoint", endpointText)
                }
            }
        }
    }

    private func editSections(_ draft: DatabaseConnectionEditDraft) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            section("Identity", symbol: "tag") {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    responsivePair {
                        field("Connection name", required: true) {
                            EdithTextField(
                                placeholder: "Connection name",
                                text: draftBinding(\.displayName, fallback: draft.displayName))
                        }
                    } right: {
                        field("Group") {
                            EdithTextField(
                                placeholder: "Optional group",
                                text: draftBinding(\.group, fallback: draft.group))
                        }
                    }
                    field("Tags") {
                        tagEditor(draft)
                    }
                    Toggle(
                        "Show this connection in favorites",
                        isOn: draftBinding(\.isFavorite, fallback: draft.isFavorite)
                    )
                    .toggleStyle(.switch)
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                }
            }
            section("Appearance", symbol: "paintpalette") {
                pickerField(
                    "Card color",
                    selection: draftBinding(\.color, fallback: draft.color)
                ) {
                    Text("Automatic").tag(nil as String?)
                    if let color = draft.color,
                        DatabaseConnectionColorToken(rawValue: color) == nil
                    {
                        Text("Custom (unchanged)").tag(Optional(color))
                    }
                    ForEach(DatabaseConnectionColorToken.allCases) { token in
                        Label {
                            Text(token.title)
                        } icon: {
                            Circle()
                                .fill(token.appTheme.color)
                                .frame(width: UIScale.pt(9), height: UIScale.pt(9))
                        }
                        .tag(Optional(token.rawValue))
                    }
                }
            }
            section("Environment", symbol: "building.2") {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    responsivePair {
                        pickerField(
                            "Environment",
                            selection: draftBinding(
                                \.environmentKind,
                                fallback: draft.environmentKind)
                        ) {
                            ForEach(DatabaseEnvironmentKind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                    } right: {
                        field("Environment label", required: true) {
                            EdithTextField(
                                placeholder: "Staging",
                                text: draftBinding(
                                    \.environmentLabel,
                                    fallback: draft.environmentLabel))
                        }
                    }
                    pickerField(
                        "Protection",
                        selection: draftBinding(
                            \.environmentProtection,
                            fallback: draft.environmentProtection)
                    ) {
                        ForEach(DatabaseEnvironmentProtection.allCases, id: \.self) { protection in
                            Text(protection.title).tag(protection)
                        }
                    }
                }
            }
            section("Safety", symbol: "checkmark.shield") {
                responsivePair {
                    pickerField(
                        "Data access",
                        selection: draftBinding(\.readOnlyPolicy, fallback: draft.readOnlyPolicy)
                    ) {
                        ForEach(DatabaseReadOnlyPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                } right: {
                    pickerField(
                        "Mutation policy",
                        selection: draftBinding(
                            \.productionPolicy,
                            fallback: draft.productionPolicy)
                    ) {
                        ForEach(DatabaseProductionPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                }
            }
        }
    }

    private var loadingEdit: some View {
        HStack(spacing: UIScale.pt(10)) {
            ProgressView().controlSize(.small)
            Text("Loading connection settings")
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(palette.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(palette.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
    }

    @ViewBuilder
    private var failureNotice: some View {
        if let failure = model.failure {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                notice(
                    failure,
                    symbol: "exclamationmark.triangle.fill",
                    tint: DashSkin.danger)
                if presentation == .edit, !isBusy {
                    if draft == nil {
                        Button("Try again") {
                            Task { await prepare() }
                        }
                        .buttonStyle(.edith(.secondary))
                    } else if model.revisionConflictConnectionID == connection.id {
                        Button("Reload latest settings") {
                            reloadLatestDraft()
                        }
                        .buttonStyle(.edith(.secondary))
                    }
                }
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(16)) {
                operationStatus
                Spacer(minLength: UIScale.pt(16))
                footerActions
            }
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                operationStatus
                HStack {
                    Spacer(minLength: 0)
                    footerActions
                }
            }
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(14))
        .background(palette.panel.opacity(0.55))
    }

    @ViewBuilder
    private var operationStatus: some View {
        if isBusy {
            HStack(spacing: UIScale.pt(8)) {
                ProgressView().controlSize(.small)
                Text(operationTitle)
            }
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .foregroundStyle(palette.inkSoft)
            .accessibilityElement(children: .combine)
        } else {
            Text(footerDetail)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(palette.inkFaint)
                .lineLimit(2)
        }
    }

    private var footerActions: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button("Cancel", action: cancel)
                .buttonStyle(.edith(.secondary))
                .disabled(preventsDismissal)
            Button(action: save) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(saveTitle)
                }
            }
            .buttonStyle(.edith(.primary, tint: palette.accent))
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
        .fixedSize()
    }

    private var canSave: Bool {
        guard !isBusy else { return false }
        switch presentation {
        case .edit:
            guard let draft else { return false }
            return !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !draft.environmentLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .rename, .duplicate:
            return hasValidName
        }
    }

    private func prepare() async {
        model.clearFailure()
        guard presentation == .edit else { return }
        guard let loaded = await model.loadEditDraft(connectionID: connection.id) else { return }
        guard !Task.isCancelled else { return }
        draft = loaded
    }

    private func save() {
        guard canSave, !submitting else { return }
        submitting = true
        Task {
            defer { submitting = false }
            switch presentation {
            case .edit:
                guard let submitted = draft else { return }
                if let result = await model.saveEditDraft(submitted) {
                    edited(result)
                }
            case .rename:
                if let result = await model.rename(
                    connectionID: connection.id,
                    displayName: name)
                {
                    renamed(result)
                }
            case .duplicate:
                if let result = await model.duplicate(
                    connectionID: connection.id,
                    displayName: name)
                {
                    duplicated(result)
                }
            }
            if let outcome = model.uncertainOutcome {
                uncertain(outcome)
            }
        }
    }

    private func reloadLatestDraft() {
        draft = nil
        Task { await prepare() }
    }

    private func draftBinding<Value>(
        _ keyPath: WritableKeyPath<DatabaseConnectionEditDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var updated = draft else { return }
                updated[keyPath: keyPath] = value
                draft = updated
            })
    }

    private func tagEditor(_ draft: DatabaseConnectionEditDraft) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            if draft.tags.isEmpty {
                Text("No tags")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(palette.inkFaint)
            }
            ForEach(Array(draft.tags.enumerated()), id: \.offset) { index, tag in
                HStack(spacing: UIScale.pt(8)) {
                    EdithTextField(
                        placeholder: "Tag",
                        text: tagBinding(at: index, fallback: tag))
                    Button {
                        removeTag(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.edith(.borderless))
                    .help("Remove tag")
                    .accessibilityLabel(tag.isEmpty ? "Remove empty tag" : "Remove tag \(tag)")
                }
            }
            Button {
                appendTag()
            } label: {
                Label("Add tag", systemImage: "plus")
            }
            .buttonStyle(.edith(.secondary))
            .disabled(draft.tags.count >= 64)
        }
    }

    private func tagBinding(at index: Int, fallback: String) -> Binding<String> {
        Binding(
            get: {
                guard let draft, draft.tags.indices.contains(index) else { return fallback }
                return draft.tags[index]
            },
            set: { value in
                guard var updated = draft, updated.tags.indices.contains(index) else { return }
                updated.tags[index] = value
                draft = updated
            })
    }

    private func appendTag() {
        guard var updated = draft, updated.tags.count < 64 else { return }
        updated.tags.append("")
        draft = updated
    }

    private func removeTag(at index: Int) {
        guard var updated = draft, updated.tags.indices.contains(index) else { return }
        updated.tags.remove(at: index)
        draft = updated
    }

    private func section<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Label(title, systemImage: symbol)
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(palette.inkSoft)
                .textCase(.uppercase)
                .tracking(0.4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(palette.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .stroke(palette.line, lineWidth: 1)
        }
    }

    private func responsivePair<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                left()
                right()
            }
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                left()
                right()
            }
        }
    }

    private func field<Content: View>(
        _ label: String,
        required: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            Text(required ? "\(label) *" : label)
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(palette.inkFaint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerField<Value: Hashable, Content: View>(
        _ label: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        field(label) {
            Picker(label, selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nameField(label: String, placeholder: String) -> some View {
        field(label, required: true) {
            EdithTextField(placeholder: placeholder, text: $name)
                .onSubmit {
                    guard canSave else { return }
                    save()
                }
        }
    }

    private func contextFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(label)
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .foregroundStyle(palette.inkFaint)
            Text(value)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(palette.ink)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .font(.system(size: UIScale.pt(11)))
        .foregroundStyle(palette.inkSoft)
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10))
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
    }

    private var endpointText: String {
        guard !connection.networkEndpoints.isEmpty else {
            return connection.product == .sqlite ? "Local database file" : "Local connection"
        }
        let visible = connection.networkEndpoints.prefix(2).map {
            "\($0.host):\($0.port.value)"
        }
        let suffix =
            connection.networkEndpoints.count > visible.count
            ? " +\(connection.networkEndpoints.count - visible.count) more"
            : ""
        return visible.joined(separator: ", ") + suffix
    }

    private var headerTitle: String {
        switch presentation {
        case .edit: "Edit metadata and safety"
        case .rename: "Rename connection"
        case .duplicate: "Duplicate connection"
        }
    }

    private var headerDetail: String {
        switch presentation {
        case .edit: "Update metadata, appearance, and safety policy for \(connection.name)."
        case .rename: "Choose a clear name for \(connection.name)."
        case .duplicate: "Create another saved connection from \(connection.name)."
        }
    }

    private var headerSymbol: String {
        switch presentation {
        case .edit: "slider.horizontal.3"
        case .rename: "pencil"
        case .duplicate: "plus.square.on.square"
        }
    }

    private var headerTint: Color {
        guard let color = connection.color, let theme = AppTheme(rawValue: color) else {
            return palette.accent
        }
        return DashSkin.accent(dark, theme: theme)
    }

    private var saveTitle: String {
        switch presentation {
        case .edit: "Save changes"
        case .rename: "Rename"
        case .duplicate: "Create copy"
        }
    }

    private var footerDetail: String {
        switch presentation {
        case .edit: "Saving may close an open session for this connection."
        case .rename: "Renaming may close an open session for this connection."
        case .duplicate: "The original connection remains unchanged."
        }
    }

    private var operationTitle: String {
        switch model.operation {
        case .loadingEdit: "Loading settings"
        case .savingEdit: "Saving changes"
        case .renaming: "Renaming connection"
        case .duplicating: "Creating copy"
        case .togglingFavorite: "Updating favorite"
        case .deleting: "Deleting connection"
        case nil: "Working"
        }
    }
}

private extension DatabaseConnectionColorToken {
    var title: String { rawValue.capitalized }

    var appTheme: AppTheme {
        AppTheme(rawValue: rawValue) ?? .accent
    }
}

private extension DatabaseProduct {
    var managementSymbolName: String {
        switch family {
        case .relational: "tablecells"
        case .keyValue: "key.horizontal"
        case .document: "doc.text"
        case .search: "magnifyingglass.circle"
        case .analytical: "chart.xyaxis.line"
        }
    }
}
