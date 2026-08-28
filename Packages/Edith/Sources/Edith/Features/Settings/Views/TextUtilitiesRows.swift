import AppKit
import EdithKit
import SwiftUI

struct TextUtilitiesRows: View {
    @AppStorage(AppStorageKeys.TextUtilities.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.TextUtilities.snippetsEnabled, store: SharedDefaults.store) private
        var snippetsEnabled = true
    @AppStorage(AppStorageKeys.TextUtilities.snippets, store: SharedDefaults.store) private
        var encodedSnippets = "[]"
    @AppStorage(AppStorageKeys.TextUtilities.cleanCopiedURLs, store: SharedDefaults.store) private
        var cleanCopiedURLs = false
    @AppStorage(
        AppStorageKeys.TextUtilities.customTrackingParameters, store: SharedDefaults.store)
    private var customTrackingParameters = ""
    @AppStorage(AppStorageKeys.TextUtilities.autoClearEnabled, store: SharedDefaults.store) private
        var autoClearEnabled = false
    @AppStorage(AppStorageKeys.TextUtilities.autoClearDelay, store: SharedDefaults.store) private
        var autoClearDelay = 30
    @AppStorage(AppStorageKeys.TextUtilities.clearOnLock, store: SharedDefaults.store) private
        var clearOnLock = false
    @AppStorage(AppStorageKeys.TextUtilities.clearOnSleep, store: SharedDefaults.store) private
        var clearOnSleep = false
    @State private var snippetQuery = ""
    @State private var editingSnippet: TextSnippet?
    @State private var deletionCandidate: TextSnippet?
    @State private var URLInput = ""
    @State private var URLResult: CleanURLResult?
    @State private var URLMessage = ""

    var body: some View {
        snippetSection
        plainTextSection
        URLSection
        autoClearSection
    }

    private var snippets: [TextSnippet] {
        TextUtilitiesSupport.decode(encodedSnippets)
    }

    private var snippetSection: some View {
        Section {
            Toggle(
                "Expand snippets while typing",
                isOn: $snippetsEnabled.configured(AppStorageKeys.TextUtilities.snippetsEnabled))
            HStack {
                TextField("Search snippets", text: $snippetQuery)
                    .textFieldStyle(.roundedBorder)
                Button {
                    editingSnippet = TextSnippet(name: "", trigger: ";", replacement: "")
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            if snippets.isEmpty {
                ContentUnavailableView(
                    "No snippets", systemImage: "text.badge.plus",
                    description: Text("Create reusable text with folders and dynamic variables."))
                    .frame(maxWidth: .infinity, minHeight: UIScale.pt(120))
            } else if filteredSections.isEmpty {
                ContentUnavailableView.search(text: snippetQuery)
                    .frame(maxWidth: .infinity, minHeight: UIScale.pt(100))
            } else {
                ForEach(filteredSections) { section in
                    snippetGroup(section)
                }
            }
        } header: {
            Text("Snippets")
        } footer: {
            Text("Use {{date}}, {{time}}, {{datetime}}, {{clipboard}}, or a custom format such as {{date:MMM d}}.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .sheet(item: $editingSnippet) { snippet in
            TextSnippetEditor(snippet: snippet) { saved in
                save(saved)
                editingSnippet = nil
            }
        }
        .confirmationDialog(
            "Delete snippet?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }),
            titleVisibility: .visible
        ) {
            if let deletionCandidate {
                Button("Delete \(deletionCandidate.name)", role: .destructive) {
                    delete(deletionCandidate)
                }
            }
        } message: {
            if let deletionCandidate {
                Text("The trigger \(deletionCandidate.trigger) will stop expanding.")
            }
        }
    }

    private var filteredSections: [TextSnippetSection] {
        TextUtilitiesSupport.sections(snippets, query: snippetQuery)
    }

    private func snippetGroup(_ section: TextSnippetSection) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Label(
                section.folder.isEmpty ? "Unfiled" : section.folder,
                systemImage: section.folder.isEmpty ? "tray" : "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(section.snippets) { snippet in
                HStack(spacing: UIScale.pt(9)) {
                    Image(systemName: snippet.enabled ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(snippet.enabled ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text(snippet.name)
                                .fontWeight(.medium)
                            Text(snippet.trigger)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(snippet.replacement.replacingOccurrences(of: "\n", with: " ↵ "))
                            .lineLimit(1)
                            .settingsCaption()
                    }
                    Spacer()
                    Menu {
                        Button("Edit") { editingSnippet = snippet }
                        Button("Duplicate") { duplicate(snippet) }
                        Divider()
                        Button("Delete", role: .destructive) { deletionCandidate = snippet }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.vertical, UIScale.pt(3))
            }
        }
    }

    private var plainTextSection: some View {
        Section("Paste as plain text") {
            LabeledContent("Shortcut") {
                HotKeyRecorderControl(keyPrefix: "textUtilitiesHotKey", defaultLabel: "⌃⌥⌘V")
            }
            Button {
                IPC.post(IPC.Name.requestPlainTextPaste)
            } label: {
                Label("Paste current clipboard as plain text", systemImage: "doc.on.clipboard")
            }
            Text("Temporarily pastes only the clipboard text, then restores the original clipboard contents.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var URLSection: some View {
        Section("Clean links") {
            Toggle(
                "Remove tracking parameters when copying links",
                isOn: $cleanCopiedURLs.configured(
                    AppStorageKeys.TextUtilities.cleanCopiedURLs))
            LabeledContent("Extra parameters") {
                TextField(
                    "ref, campaign", text: $customTrackingParameters.configured(
                        AppStorageKeys.TextUtilities.customTrackingParameters))
                    .multilineTextAlignment(.trailing)
            }
            TextField("Paste a URL to clean", text: $URLInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(cleanURL)
            HStack {
                Button("Clean URL", action: cleanURL)
                if let URLResult {
                    Button("Copy cleaned URL") { copy(URLResult.value) }
                }
                Spacer()
            }
            if let URLResult {
                Text(URLResult.value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(
                    URLResult.removedParameters.isEmpty
                        ? "No tracking parameters found."
                        : "Removed: \(URLResult.removedParameters.joined(separator: ", "))")
                    .settingsCaption()
            } else if !URLMessage.isEmpty {
                Text(URLMessage)
                    .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var autoClearSection: some View {
        Section("Clipboard privacy") {
            Toggle(
                "Clear copied content automatically",
                isOn: $autoClearEnabled.configured(
                    AppStorageKeys.TextUtilities.autoClearEnabled))
            Stepper(
                "Clear after \(autoClearDelay) seconds", value: $autoClearDelay.configured(
                    AppStorageKeys.TextUtilities.autoClearDelay), in: 5...3_600, step: 5)
                .disabled(!autoClearEnabled)
            Toggle(
                "Clear when the screen locks",
                isOn: $clearOnLock.configured(AppStorageKeys.TextUtilities.clearOnLock))
            Toggle(
                "Clear before the Mac sleeps",
                isOn: $clearOnSleep.configured(AppStorageKeys.TextUtilities.clearOnSleep))
            Text("Only the unchanged clipboard generation is cleared, so newer copies are never erased by an older timer.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func save(_ snippet: TextSnippet) {
        var updated = snippets
        if let index = updated.firstIndex(where: { $0.id == snippet.id }) {
            updated[index] = snippet
        } else {
            updated.append(snippet)
        }
        store(updated)
    }

    private func duplicate(_ snippet: TextSnippet) {
        var copy = snippet
        copy.id = UUID()
        copy.name += " Copy"
        store(snippets + [copy])
    }

    private func delete(_ snippet: TextSnippet) {
        store(snippets.filter { $0.id != snippet.id })
    }

    private func store(_ snippets: [TextSnippet]) {
        let value = TextUtilitiesSupport.encode(snippets)
        try? ConfigurationExecutor.application.set(
            .string(value), forKey: AppStorageKeys.TextUtilities.snippets)
        encodedSnippets = value
    }

    private func cleanURL() {
        URLResult = TextUtilitiesSupport.cleanURL(
            URLInput,
            customParameters: TextUtilitiesSupport.customParameters(customTrackingParameters))
        URLMessage = URLResult == nil ? "Enter a complete http or https URL." : ""
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct TextSnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TextSnippet
    let save: (TextSnippet) -> Void

    init(snippet: TextSnippet, save: @escaping (TextSnippet) -> Void) {
        _draft = State(initialValue: snippet)
        self.save = save
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            HStack {
                Text(draft.name.isEmpty ? "New snippet" : "Edit snippet")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(normalizedDraft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(UIScale.pt(18))
            Divider()
            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                    TextField("Trigger", text: $draft.trigger)
                    TextField("Folder", text: $draft.folder)
                }
                Section("Expansion") {
                    Picker("Expand", selection: $draft.expansion) {
                        Text("After delimiter").tag(TextSnippetExpansion.afterDelimiter)
                        Text("Immediately").tag(TextSnippetExpansion.immediate)
                    }
                    Toggle("Ignore trigger case", isOn: $draft.ignoresCase)
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                Section("Replacement") {
                    TextEditor(text: $draft.replacement)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: UIScale.pt(120))
                    HStack {
                        variableButton("Date", value: "{{date}}")
                        variableButton("Time", value: "{{time}}")
                        variableButton("Clipboard", value: "{{clipboard}}")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: UIScale.pt(500), height: UIScale.pt(540))
    }

    private var normalizedDraft: TextSnippet {
        var value = draft
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.trigger = TextUtilitiesSupport.sanitizedTrigger(value.trigger)
        value.folder = TextUtilitiesSupport.sanitizedFolder(value.folder)
        return value
    }

    private var canSave: Bool {
        !normalizedDraft.name.isEmpty && !normalizedDraft.trigger.isEmpty
            && !normalizedDraft.replacement.isEmpty
    }

    private func variableButton(_ title: String, value: String) -> some View {
        Button(title) { draft.replacement += value }
            .buttonStyle(.bordered)
    }
}
