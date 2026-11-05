import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct BifrostQuicklinkEditor: View {
    @State private var items: [BifrostQuicklink] = []

    var body: some View {
        BifrostLibrarySection(
            items: $items, noun: ("quicklink", "quicklinks"),
            caption:
                "Open a site or a search from the launcher. Put {query} where the text you type should go.",
            make: { BifrostQuicklink(name: "New quicklink", target: "https://") },
            store: AppStorageKeys.Bifrost.quicklinks
        ) { item in
            BifrostFieldGrid {
                BifrostField("Name", text: item.name, prompt: "Search the docs")
                BifrostField(
                    "Address", text: item.target, prompt: "https://example.com/search?q={query}")
                BifrostField("Keyword", text: item.keyword, prompt: "Optional, for example gh")
            }
        }
        .onAppear { items = BifrostLibraryStore.quicklinks() }
    }
}

struct BifrostSnippetEditor: View {
    @State private var items: [BifrostSnippet] = []

    var body: some View {
        BifrostLibrarySection(
            items: $items, noun: ("snippet", "snippets"),
            caption:
                "Text you type often. Search its name or keyword in the launcher to paste it. {clipboard} and {date} are filled in for you.",
            make: { BifrostSnippet(name: "New snippet", content: "") },
            store: AppStorageKeys.Bifrost.snippets
        ) { item in
            BifrostFieldGrid {
                BifrostField("Name", text: item.name, prompt: "Meeting link")
                GridRow(alignment: .top) {
                    BifrostFieldLabel("Text").padding(.top, UIScale.pt(5))
                    TextEditor(text: item.content)
                        .font(.system(size: UIScale.pt(12), design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(UIScale.pt(4))
                        .frame(height: UIScale.pt(64))
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: UIScale.pt(6))
                                .strokeBorder(Color.secondary.opacity(0.3))
                        )
                        .accessibilityLabel("Snippet text")
                }
                BifrostField("Keyword", text: item.keyword, prompt: "Optional, for example meet")
            }
        }
        .onAppear { items = BifrostLibraryStore.snippets() }
    }
}

struct BifrostShellCommandEditor: View {
    @State private var items: [BifrostShellCommand] = []

    var body: some View {
        BifrostLibrarySection(
            items: $items, noun: ("command", "commands"),
            caption: "Run a script by name from the launcher. Commands run in your login shell.",
            make: { BifrostShellCommand(name: "New command", script: "") },
            store: AppStorageKeys.Bifrost.shellCommands
        ) { item in
            BifrostFieldGrid {
                BifrostField("Name", text: item.name, prompt: "Say hello")
                BifrostField("Command", text: item.script, prompt: "echo hello")
                BifrostField("Keyword", text: item.keyword, prompt: "Optional")
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Show the output when it finishes", isOn: item.showsOutput)
                        .toggleStyle(.checkbox)
                }
            }
        }
        .onAppear { items = BifrostLibraryStore.shellCommands() }
    }
}

struct BifrostFieldGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: UIScale.pt(12), verticalSpacing: UIScale.pt(8))
        {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BifrostFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

struct BifrostField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    init(_ title: String, text: Binding<String>, prompt: String) {
        self.title = title
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            BifrostFieldLabel(title)
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
        }
    }
}

struct BifrostLibrarySection<Item: Identifiable & Codable & Equatable, Fields: View>: View {
    @Binding var items: [Item]
    let noun: (singular: String, plural: String)
    let caption: String
    let make: () -> Item
    let store: String
    @ViewBuilder let fields: (Binding<Item>) -> Fields

    var body: some View {
        Group {
            ForEach($items) { item in
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    fields(item)
                    Button {
                        remove(item.wrappedValue.id)
                    } label: {
                        EdithIconView(.trash)
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .help("Delete this \(noun.singular)")
                    .accessibilityLabel("Delete this \(noun.singular)")
                }
                .padding(.vertical, UIScale.pt(4))
            }
            LabeledContent {
                Button("Add \(noun.singular.capitalized)") {
                    items.append(make())
                    save()
                }
                .buttonStyle(.edith(.secondary))
            } label: {
                Text(
                    items.isEmpty
                        ? "No \(noun.plural) yet"
                        : items.count == 1 ? "1 \(noun.singular)" : "\(items.count) \(noun.plural)")
                Text(caption)
            }
        }
        .onChange(of: items) { _, _ in save() }
    }

    private func remove(_ identifier: Item.ID) {
        items.removeAll { $0.id == identifier }
        save()
    }

    private func save() {
        BifrostUIContext.write(store, value: BifrostLibrary.encode(items))
    }
}
