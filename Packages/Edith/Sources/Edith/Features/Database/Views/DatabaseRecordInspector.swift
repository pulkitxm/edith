import AppKit
import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseRecordInspector: View {
    let data: DatabaseDataWorkspaceModel
    let mutations: DatabaseWorkspaceModel
    let connection: DatabaseConnectionSummary
    let palette: DatabaseThemePalette
    let canUpdate: Bool
    let canDelete: Bool
    @State private var showsSource = false
    private var usesDocuments: Bool { DatabaseDataWorkspaceModel.usesDocumentEditor(connection) }
    private var noun: String {
        connection.product.family == .keyValue ? "key" : usesDocuments ? "document" : "row"
    }

    var body: some View {
        Group {
            if data.editorMode != nil {
                editor
            } else if let record = data.selectedRecord {
                details(record)
            }
        }.background(palette.panel)
    }

    private func details(_ record: DatabaseRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(10)) {
                Text("\(noun.capitalized) details").font(
                    .system(size: UIScale.pt(12), weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    guard let source = data.documentSource(record) else {
                        AccessibilityAnnouncement.post(
                            "This record contains values that cannot be copied as JSON.")
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy \(noun) as JSON").accessibilityLabel("Copy \(noun) as JSON")
                if canUpdate && data.canMutateSelectedRecord(.update, connection: connection) {
                    Button {
                        data.beginEditingSelectedRow(connection)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .disabled(mutations.hasTrackedMutation).help("Edit \(noun)").accessibilityLabel(
                        "Edit \(noun)")
                }
                if canDelete && data.canMutateSelectedRecord(.delete, connection: connection) {
                    Button(role: .destructive) {
                        if let request = data.deleteMutationRequest(connection) {
                            mutations.requestSafetyReview(for: request)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(mutations.hasTrackedMutation).help("Delete \(noun)")
                    .accessibilityLabel("Delete \(noun)")
                }
                Button {
                    if let index = data.selectedRecordIndex { data.selectRecord(at: index) }
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction).help("Close \(noun) details").accessibilityLabel(
                    "Close \(noun) details")
            }
            .buttonStyle(.edith(.borderless)).padding(.horizontal, UIScale.pt(12)).frame(
                height: UIScale.pt(38))
            Divider()
            if usesDocuments {
                Picker("Document view", selection: $showsSource) {
                    Text("Tree").tag(false)
                    Text("Source").tag(true)
                }.pickerStyle(.segmented).labelsHidden().padding(UIScale.pt(10))
                if record.identity?.kind == .searchDocument, let identity = record.identity {
                    Text(
                        (identity.components + identity.concurrencyTokens).map {
                            "\($0.name): \(data.text(for: $0.value))"
                        }.joined(separator: " · ")
                    )
                    .font(.system(size: UIScale.pt(10), design: .monospaced)).foregroundStyle(
                        .secondary
                    )
                    .textSelection(.enabled).padding(.horizontal, UIScale.pt(12))
                }
            }
            ScrollView {
                if usesDocuments {
                    document(record)
                } else {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        ForEach(Array(record.fields.enumerated()), id: \.offset) { _, field in
                            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                                Text(field.name).font(
                                    .system(size: UIScale.pt(10.5), weight: .semibold)
                                ).foregroundStyle(.secondary)
                                Text(data.text(for: field.value)).font(
                                    .system(size: UIScale.pt(11), design: .monospaced)
                                )
                                .textSelection(.enabled).frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(UIScale.pt(12))
                }
            }
        }
    }

    private func document(_ record: DatabaseRecord) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            if showsSource {
                Text(
                    data.documentSource(record)
                        ?? "Source view is unavailable for one or more unsupported values."
                )
                .font(.system(size: UIScale.pt(11), design: .monospaced)).textSelection(.enabled)
            } else {
                DatabaseDocumentOutline(
                    nodes: DatabaseDocumentNode.fields(
                        record.fields.filter { $0.name != "_highlight" }), text: data.text(for:))
            }
            if let highlight = record.fields.first(where: { $0.name == "_highlight" }) {
                Divider()
                Text("Highlights").font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(.secondary)
                DatabaseDocumentOutline(
                    nodes: DatabaseDocumentNode.fields([highlight]), text: data.text(for:))
            }
        }.padding(UIScale.pt(12)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(data.editorMode == .insert ? "New" : "Edit") \(noun)")
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                Spacer()
                Button("Cancel", action: data.cancelEditor).buttonStyle(.edith(.borderless))
                Button("Review") {
                    if let request = data.editorMutationRequest(connection) {
                        mutations.requestSafetyReview(for: request)
                    }
                }
                .buttonStyle(.edith(.primary, tint: palette.accent))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(mutations.hasTrackedMutation || !data.canSubmitEditor)
            }.padding(UIScale.pt(12))
            Divider()
            if let error = data.editorError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(DashSkin.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(UIScale.pt(12))
            }
            if usesDocuments {
                TextEditor(text: Binding(get: { data.documentText }, set: data.updateDocumentText))
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(UIScale.pt(12)).accessibilityLabel(
                        "\(connection.product.displayName) document JSON")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        if data.editorMode == .insert, connection.product.family == .relational {
                            Text(
                                "Unchecked fields use database defaults. Required fields without a default need a value."
                            )
                            .font(.system(size: UIScale.pt(10.5))).foregroundStyle(.secondary)
                        }
                        ForEach(data.editorFields) { field in editorField(field) }
                    }.padding(UIScale.pt(12))
                }
            }
        }
    }

    private func editorField(_ field: DatabaseRowFieldDraft) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(6)) {
                Toggle(
                    "Include \(field.id)",
                    isOn: Binding(
                        get: { field.isIncluded },
                        set: { data.setEditorFieldIncluded(field.id, included: $0) })
                )
                .labelsHidden().toggleStyle(.checkbox).disabled(!field.isEditable)
                .help("Include \(field.id) in this change")
                Text(field.id).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                Text(field.typeName).font(.system(size: UIScale.pt(9.5))).foregroundStyle(
                    .secondary
                ).lineLimit(1)
                Spacer(minLength: 0)
                if field.isGenerated || field.isIdentity {
                    Text(field.isGenerated ? "generated" : "key").font(
                        .system(size: UIScale.pt(9.5))
                    ).foregroundStyle(.secondary)
                } else if field.isEditable {
                    if field.isIncluded {
                        Button {
                            data.resetEditorField(field.id)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.edith(.borderless)).help("Reset \(field.id)")
                    }
                    if connection.product.family == .keyValue {
                        if field.id == "ttlMilliseconds" {
                            Button("No expiry") { data.updateEditorField(field.id, text: "-1") }
                                .buttonStyle(.edith(.borderless))
                        }
                    } else if field.isNullable {
                        Button("NULL") { data.setEditorFieldNull(field.id) }.buttonStyle(
                            .edith(.borderless))
                    }
                }
            }
            fieldInput(field)
            if data.editorMode == .insert, !field.isGenerated, !field.isIncluded {
                Text(
                    field.hasDefault
                        ? "Uses database default"
                        : field.isNullable ? "Uses NULL" : "Requires a value"
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            }
        }.opacity(field.isEditable ? 1 : 0.62)
    }

    @ViewBuilder
    private func fieldInput(_ field: DatabaseRowFieldDraft) -> some View {
        if field.isGenerated {
            Text(data.editorMode == .insert ? "Generated by database" : field.text)
                .font(.system(size: UIScale.pt(10.5), design: .monospaced)).foregroundStyle(
                    .secondary)
        } else if let values = field.choiceValues {
            Picker(
                field.id,
                selection: Binding(
                    get: { field.isNull ? -1 : values.firstIndex(of: field.text) ?? -2 },
                    set: { index in
                        if index == -1 {
                            data.setEditorFieldNull(field.id)
                        } else if values.indices.contains(index) {
                            data.updateEditorField(field.id, text: values[index])
                        }
                    })
            ) {
                Text("Choose a value").tag(-2).disabled(true)
                if field.isNullable { Text("NULL (no value)").tag(-1) }
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Text(value).tag(index)
                }
            }.labelsHidden().disabled(!field.isEditable)
        } else if field.isNull {
            HStack {
                Text("NULL (no value)").foregroundStyle(.secondary)
                Spacer()
                Button("Set value") { data.updateEditorField(field.id, text: "") }
                    .buttonStyle(.edith(.borderless)).disabled(!field.isEditable)
            }
        } else if field.isJSON {
            TextEditor(text: fieldText(field.id)).font(
                .system(size: UIScale.pt(10.5), design: .monospaced)
            )
            .frame(minHeight: UIScale.pt(100), maxHeight: UIScale.pt(160))
            .accessibilityLabel("\(field.id) JSON").disabled(!field.isEditable)
        } else {
            TextField("Value", text: fieldText(field.id)).textFieldStyle(.roundedBorder)
                .font(.system(size: UIScale.pt(10.5), design: .monospaced)).disabled(
                    !field.isEditable)
        }
    }

    private func fieldText(_ id: String) -> Binding<String> {
        Binding(
            get: { data.editorFields.first { $0.id == id }?.text ?? "" },
            set: { data.updateEditorField(id, text: $0) })
    }
}
