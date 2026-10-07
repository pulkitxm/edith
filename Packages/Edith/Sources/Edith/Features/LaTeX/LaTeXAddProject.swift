import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct LaTeXAddProject: View {
    let model: LaTeXModel
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var location = LaTeXLocation.disk
    @State private var compiler = LaTeXCompiler.tectonic
    @State private var name = ""
    @State private var sourcePath = ""
    @State private var repository = ""
    @State private var branch = ""
    @State private var busy = false
    @State private var error: String?

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
            EdithSegmentedPicker(
                "Compiler", selection: $compiler, options: LaTeXCompiler.allCases,
                label: { $0.title }
            ).disabled(busy)
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                field("Project name", placeholder: "Research paper", text: $name)
                if location == .github {
                    field("Repository", placeholder: "owner/repository", text: $repository)
                    field("Base branch", placeholder: "Repository default", text: $branch)
                    field("Source path", placeholder: "papers/main.tex", text: $sourcePath)
                    Text(
                        "GitHub holds the source and compiled PDFs. Submitting changes adds a compiler workflow and opens a pull request. Review with Quinjet, then squash merge now or after checks pass."
                    )
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .bottom) {
                        field("Source file", placeholder: "/path/to/main.tex", text: $sourcePath)
                        Button("Choose file…") { chooseFile() }
                    }
                    Text(
                        "The source stays on this Mac. Save & compile writes a PDF beside the .tex file."
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
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || sourcePath.isEmpty
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: UIScale.pt(520), height: UIScale.pt(510))
        .transientPresentation(
            dismissible: !busy && name.isEmpty && sourcePath.isEmpty && repository.isEmpty)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Text(title).font(.edithText(.headline))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                .font(.edithText(.body)).accessibilityLabel(title)
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
        Task {
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
