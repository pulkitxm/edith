import EdithKit
import SwiftUI

struct BifrostQuicklinkEditor: View {
    @State private var items: [BifrostQuicklink] = []

    var body: some View {
        BifrostLibrarySection(
            items: $items, addTitle: "Add quicklink",
            caption: "Use {query} for typed input, {clipboard} or {date} anywhere in the target.",
            make: { BifrostQuicklink(name: "New quicklink", target: "https://") },
            store: AppStorageKeys.Bifrost.quicklinks
        ) { item in
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                TextField("Name", text: item.name)
                    .textFieldStyle(.roundedBorder)
                TextField("https://example.com/search?q={query}", text: item.target)
                    .textFieldStyle(.roundedBorder)
                TextField("Keyword, for example gh", text: item.keyword)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onAppear { items = BifrostLibraryStore.quicklinks() }
    }
}

struct BifrostSnippetEditor: View {
    @State private var items: [BifrostSnippet] = []

    var body: some View {
        BifrostLibrarySection(
            items: $items, addTitle: "Add snippet",
            caption: "Placeholders work here too, and the result is pasted for you.",
            make: { BifrostSnippet(name: "New snippet", content: "") },
            store: AppStorageKeys.Bifrost.snippets
        ) { item in
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                TextField("Name", text: item.name)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: item.content)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: UIScale.pt(60))
                    .border(Color.secondary.opacity(0.3))
                TextField("Keyword", text: item.keyword)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onAppear { items = BifrostLibraryStore.snippets() }
    }
}

struct BifrostShellCommandEditor: View {
    @State private var items: [BifrostShellCommand] = []

    var body: some View {
        BifrostLibrarySection(
            items: $items, addTitle: "Add command",
            caption: "Commands run through your login shell and can show their output.",
            make: { BifrostShellCommand(name: "New command", script: "") },
            store: AppStorageKeys.Bifrost.shellCommands
        ) { item in
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                TextField("Name", text: item.name)
                    .textFieldStyle(.roundedBorder)
                TextField("echo hello", text: item.script)
                    .textFieldStyle(.roundedBorder)
                TextField("Keyword", text: item.keyword)
                    .textFieldStyle(.roundedBorder)
                Toggle("Show the output when it finishes", isOn: item.showsOutput)
            }
        }
        .onAppear { items = BifrostLibraryStore.shellCommands() }
    }
}

struct BifrostLibrarySection<Item: Identifiable & Codable & Equatable, Fields: View>: View {
    @Binding var items: [Item]
    let addTitle: String
    let caption: String
    let make: () -> Item
    let store: String
    @ViewBuilder let fields: (Binding<Item>) -> Fields

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            ForEach($items) { item in
                HStack(alignment: .top, spacing: UIScale.pt(8)) {
                    fields(item)
                    Button {
                        remove(item.wrappedValue.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: UIScale.pt(8)) {
                Button(addTitle) {
                    items.append(make())
                    save()
                }
                Spacer()
                Text("\(items.count) saved")
                    .settingsCaption()
            }
            Text(caption).settingsCaption()
        }
        .onChange(of: items) { _, _ in save() }
    }

    private func remove(_ identifier: Item.ID) {
        items.removeAll { $0.id == identifier }
        save()
    }

    private func save() {
        try? ConfigurationExecutor.application.set(
            .string(BifrostLibrary.encode(items)), forKey: store)
    }
}
