import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import UniformTypeIdentifiers

struct LaTeXAddProject: View {
    let model: LaTeXModel
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var location: LaTeXLocation
    @State private var compiler: LaTeXCompiler
    @State private var name = ""
    @State private var sourcePath = ""
    @State private var repository = ""
    @State private var branch = ""
    @State private var busy = false
    @State private var error: String?

    init(
        model: LaTeXModel, location: LaTeXLocation = .disk, onAdded: @escaping () -> Void
    ) {
        self.model = model
        self.onAdded = onAdded
        _location = State(initialValue: location)
        _compiler = State(initialValue: location == .github ? .pdfLatex : .tectonic)
    }

    var body: some View {
        PageScaffold(width: .readable) {
            PageHeader(
                "Add LaTeX project",
                trailing: {
                    Button("Cancel") { dismiss() }.disabled(busy)
                })
        } content: {
            EdithSegmentedPicker(
                "Storage", selection: $location, options: LaTeXLocation.allCases,
                label: { $0.title }
            )
            .disabled(busy)
            .onChange(of: location) { _, _ in
                sourcePath = ""; error = nil
                compiler = location == .github ? .pdfLatex : .tectonic
            }
            Text(location.summary).font(.edithText(.subheadline)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text("Compiler").font(.edithText(.headline))
                EdithSegmentedPicker(
                    "Compiler", selection: $compiler, options: LaTeXCompiler.allCases,
                    label: { $0.title }
                ).disabled(busy)
                Text(compiler.summary).font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                field("Project name", placeholder: "Research paper", text: $name)
                if location == .github {
                    field("Repository", placeholder: "owner/repository", text: $repository)
                    field("Base branch", placeholder: "Repository default", text: $branch)
                    field("Source path", placeholder: "papers/main.tex", text: $sourcePath)
                    Text(
                        "Nothing is cloned to your Mac. The first save adds a PDF build workflow and opens a pull request you can review and merge. Requires GitHub access through Pukbot."
                    )
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .bottom) {
                        field("Source file", placeholder: "/path/to/main.tex", text: $sourcePath)
                        Button("Choose file…") { chooseFile() }
                            .buttonStyle(.edith(.secondary))
                    }
                    Text(
                        "Your file is never moved or copied. Edith only reads it and saves your edits back to it."
                    )
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                }
            }.disabled(busy)
            if let error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if busy { LoadingIndicator(); Text("Checking source…").font(.edithText(.caption)) }
                Spacer()
                Button("Add project") { add() }
                    .buttonStyle(.edith(.primary))
                    .disabled(!canAdd)
                    .help(addDisabledReason ?? "Add this project to your library")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: UIScale.pt(520), height: UIScale.pt(510))
        .transientPresentation(
            dismissible: !busy && name.isEmpty && sourcePath.isEmpty && repository.isEmpty)
    }

    private var canAdd: Bool { !busy && addDisabledReason == nil }

    private var addDisabledReason: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the project a name first."
        }
        if sourcePath.isEmpty {
            return location == .disk
                ? "Choose a .tex file first." : "Enter the path of the .tex file in the repository."
        }
        if location == .github && repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Enter the repository as owner/repository."
        }
        return nil
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Text(title).font(.edithText(.headline))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.edithText(.body))
                .accessibilityLabel(title)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func add() {
        busy = true
        error = nil
        model.launch {
            defer { busy = false }
            do {
                try await model.add(
                    LaTeXProject(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        location: location,
                        sourcePath: sourcePath.trimmingCharacters(in: .whitespacesAndNewlines),
                        compiler: compiler,
                        repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                        baseBranch: branch.trimmingCharacters(in: .whitespacesAndNewlines)))
                onAdded()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
