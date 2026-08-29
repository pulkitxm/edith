import EdithKit
import SwiftUI

struct ScratchpadPanelView: View {
    @Bindable var store: ScratchpadStore
    let dismiss: () -> Void
    @State private var renamePresented = false
    @State private var renameValue = ""
    @State private var removePresented = false
    @State private var clearPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabs
            Divider()
            editor
            Divider()
            footer
        }
        .tint(brandAccent)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.38))
        .onExitCommand(perform: dismiss)
        .alert("Rename pad", isPresented: $renamePresented) {
            TextField("Name", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameSelected(to: renameValue) }
        }
        .alert("Delete this pad?", isPresented: $removePresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { store.removeSelected() }
        } message: {
            Text("The pad and its text will be removed. This cannot be undone.")
        }
        .alert("Clear this pad?", isPresented: $clearPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clearSelected() }
        } message: {
            Text("All text in this pad will be removed. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Scratchpad", systemImage: "note.text")
                .font(.system(size: 13, weight: .semibold))
            TextField("Search pads", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Spacer()
            Picker("Mode", selection: $store.previewing) {
                Text("Plain text").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
            Menu {
                Button("New pad", action: store.create)
                Button("Rename pad") { presentRename() }
                Button("Duplicate pad", action: store.duplicateSelected)
                Divider()
                Button("Copy all", action: store.copyAll)
                Button("Export...", action: store.exportSelected)
                if store.companionEnabled {
                    Button("Remember in Companion") {
                        Task { await store.rememberSelected() }
                    }
                    .disabled(store.remembering || store.selectedText.isEmpty)
                }
                Divider()
                Button("Clear pad", role: .destructive) { clearPresented = true }
                Button("Delete pad", role: .destructive) { removePresented = true }
                    .disabled(store.document.pads.count == 1)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .menuIndicator(.hidden)
            .buttonStyle(.edith(.toolbar))
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.edith(.toolbar))
            .help("Close Scratchpad")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.searchResults, id: \.pad.id) { result in
                    Button {
                        store.select(result.pad.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text(result.pad.name)
                                .lineLimit(1)
                            if !store.query.isEmpty {
                                Text(String(result.matchCount))
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(
                        .edith(.selection, selected: result.pad.id == store.document.selectedID)
                    )
                    .contextMenu {
                        Button("Rename") {
                            store.select(result.pad.id)
                            presentRename()
                        }
                        Button("Duplicate") {
                            store.select(result.pad.id)
                            store.duplicateSelected()
                        }
                        Button("Delete", role: .destructive) {
                            store.select(result.pad.id)
                            removePresented = true
                        }
                        .disabled(store.document.pads.count == 1)
                    }
                }
                Button(action: store.create) {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.edith(.toolbar))
                .help("New pad")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder private var editor: some View {
        if store.previewing {
            ScrollView {
                ScratchpadMarkdownPreview(source: store.selectedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.38))
        } else {
            TextEditor(
                text: Binding(
                    get: { store.selectedText },
                    set: { store.selectedText = $0 })
            )
            .font(.system(size: 14, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.38))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let words = store.selectedText.split { $0.isWhitespace || $0.isNewline }.count
            Text("\(words) words  ·  \(store.selectedText.count) characters")
                .foregroundStyle(.secondary)
            Spacer()
            if let failure = store.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(failure)
            } else if let outcome = store.outcome {
                Text(outcome)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    store.savePending ? "Saving" : "Saved",
                    systemImage: store.savePending ? "arrow.triangle.2.circlepath" : "checkmark"
                )
                .foregroundStyle(.secondary)
            }
            if store.companionEnabled {
                Button {
                    Task { await store.rememberSelected() }
                } label: {
                    Label("Remember", systemImage: "brain.head.profile")
                }
                .buttonStyle(.edith(.secondary))
                .disabled(store.remembering || store.selectedText.isEmpty)
                .help("Promote this pad into Companion memory")
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func presentRename() {
        renameValue = store.selectedPad?.name ?? ""
        renamePresented = true
    }
}

private struct ScratchpadMarkdownPreview: View {
    let source: String

    private var lines: [ScratchpadMarkdownLine] {
        ScratchpadMarkdownLine.parse(source)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(lines) { line in
                row(line)
            }
        }
    }

    @ViewBuilder private func row(_ line: ScratchpadMarkdownLine) -> some View {
        switch line.kind {
        case .blank:
            Color.clear.frame(height: 5)
        case let .heading(level):
            Text(inline(line.text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level == 1 ? 5 : 2)
        case let .list(marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                Text(inline(line.text))
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary.opacity(0.55))
                    .frame(width: 3)
                Text(inline(line.text))
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.06))
        case .rule:
            Divider().padding(.vertical, 4)
        case .body:
            Text(inline(line.text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 25
        case 2: 21
        case 3: 18
        case 4: 16
        default: 14
        }
    }
}

private struct ScratchpadMarkdownLine: Identifiable {
    enum Kind {
        case blank
        case heading(Int)
        case list(String)
        case quote
        case code
        case rule
        case body
    }

    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ source: String) -> [ScratchpadMarkdownLine] {
        var code = false
        var result: [ScratchpadMarkdownLine] = []
        let rawLines = source.components(separatedBy: .newlines)
        for (index, rawLine) in rawLines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                code.toggle()
                continue
            }
            if code {
                result.append(.init(id: index, kind: .code, text: rawLine))
                continue
            }
            if trimmed.isEmpty {
                result.append(.init(id: index, kind: .blank, text: ""))
                continue
            }
            if Set(trimmed) == Set("-") && trimmed.count >= 3 {
                result.append(.init(id: index, kind: .rule, text: ""))
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                let text = String(trimmed.dropFirst(hashes + 1))
                result.append(.init(id: index, kind: .heading(hashes), text: text))
                continue
            }
            if let marker = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
                result.append(
                    .init(
                        id: index, kind: .list("•"), text: String(trimmed.dropFirst(marker.count))))
                continue
            }
            if trimmed.hasPrefix("> ") {
                result.append(.init(id: index, kind: .quote, text: String(trimmed.dropFirst(2))))
                continue
            }
            if let separator = trimmed.firstIndex(of: ".") {
                let number = trimmed[..<separator]
                let remainder = trimmed[trimmed.index(after: separator)...]
                if !number.isEmpty, number.allSatisfy(\.isNumber), remainder.first == " " {
                    result.append(
                        .init(
                            id: index,
                            kind: .list("\(number)."),
                            text: String(remainder.dropFirst())))
                    continue
                }
            }
            result.append(.init(id: index, kind: .body, text: rawLine))
        }
        return result
    }
}
