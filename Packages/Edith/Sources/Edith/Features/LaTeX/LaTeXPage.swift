import AppKit
import EdithKit
import PDFKit
import SwiftUI

struct LaTeXPage: View {
    @Environment(\.windowSessionOwner) private var owner
    @StateObject private var fallback = WindowSessionOwner()
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var editing = false
    @State private var adding = false
    @State private var showingReview = false
    @State private var inspector = "PDF"
    private let providedModel: LaTeXModel?
    init(model: LaTeXModel? = nil, opensEditor: Bool = false) {
        providedModel = model
        _editing = State(initialValue: opensEditor)
    }
    private var model: LaTeXModel { providedModel ?? owner?.latex ?? fallback.latex }

    var body: some View {
        Group {
            if editing, let project = model.selected {
                PageWorkspace {
                    PageHeader("LaTeX editor") {
                        Button {
                            editing = false
                        } label: {
                            Label("Back to projects", systemImage: "chevron.left")
                        }.disabled(model.dirty || model.busy)
                    }
                } content: {
                    workspace(project)
                }
            } else {
                projectsPage
            }
        }
        .pageTask { await model.start() }
        .edithSheet(isPresented: $adding, dismissible: nil) {
            LaTeXAddProject(model: model, onAdded: { editing = true })
        }
        .edithSheet(isPresented: $showingReview) {
            LaTeXReviewSheet(model: model).frame(minWidth: 520, idealWidth: 780, minHeight: 480)
        }
        .onChange(of: model.selectedID) { _, id in if id == nil { editing = false } }
    }

    private var projectsPage: some View {
        PageScaffold {
            PageHeader("LaTeX projects") {
                Button {
                    adding = true
                } label: {
                    Label("Add project", systemImage: "plus")
                }
                .disabled(model.busy || model.load.isRunning)
            } accessory: {
                Text("Your documents, on this Mac and on GitHub.")
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
            }
        } content: {
            PageLoading(
                state: model.projects.isEmpty ? model.load.state : .content,
                title: "Your first LaTeX project",
                message: model.load.errorMessage
                    ?? "Add a .tex file from this Mac or a source path in a GitHub repository.",
                layout: .cards, retry: { Task { await model.start() } }
            ) {
                LazyVGrid(
                    columns: PageMetrics.cardColumns(compact, minimum: 300, spacing: 16),
                    spacing: UIScale.pt(16)
                ) {
                    ForEach(model.projects) { project in projectCard(project) }
                }
            }
        }
    }

    private func projectCard(_ project: LaTeXProject) -> some View {
        Button {
            Task {
                editing = true
                await model.select(project.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                HStack {
                    Image(
                        systemName: project.location == .disk
                            ? "doc.richtext" : "arrow.triangle.branch"
                    )
                    .font(.system(size: UIScale.pt(24))).foregroundStyle(.tint)
                    Spacer()
                    Text(project.location.title).font(.edithText(.caption)).foregroundStyle(
                        .secondary)
                }
                Text(project.name).font(.edithText(.title3)).foregroundStyle(.primary)
                Text(
                    project.location == .disk
                        ? URL(fileURLWithPath: project.sourcePath).lastPathComponent
                        : project.repository
                )
                .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                Text(
                    project.location == .disk
                        ? "Compile and save PDFs on this Mac"
                        : "\(project.sourcePath) · \(project.baseBranch)"
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(2)
                Divider()
                HStack {
                    if let number = project.pullRequest {
                        Label("Pull request #\(number)", systemImage: "arrow.triangle.pull")
                            .font(.edithText(.caption)).foregroundStyle(.green)
                    }
                    Spacer()
                    Label("Open editor", systemImage: "arrow.right")
                        .font(.edithText(.subheadline)).foregroundStyle(.tint)
                }
            }
            .padding(UIScale.pt(20))
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(190), alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: UIScale.pt(14)).fill(DashSkin.paper(scheme == .dark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(
                    Color.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .disabled(model.busy || model.load.isRunning)
    }

    private func workspace(_ project: LaTeXProject) -> some View {
        VStack(spacing: 0) {
            controls(project)
            if model.dirty {
                HStack {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.edithText(.caption)).foregroundStyle(.orange)
                    Spacer()
                    Button("Discard edits") { model.discard() }.disabled(model.busy)
                }.pageGutter(compact).padding(.bottom, UIScale.pt(8))
            }
            if let message = model.message ?? model.load.errorMessage {
                HStack {
                    Text(message).font(.edithText(.caption)).textSelection(.enabled)
                    Spacer()
                    if model.load.errorMessage != nil {
                        Button("Retry") { Task { await model.reload() } }.disabled(model.dirty)
                    }
                }.pageGutter(compact).padding(.bottom, UIScale.pt(10))
            }
            if model.load.isRunning || model.busy {
                HStack {
                    LoadingIndicator()
                    Text(model.busy ? "Working on your document…" : "Loading source…")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }.padding(UIScale.pt(8))
            }
            if model.original != nil {
                if compact {
                    VSplitView {
                        editor.frame(minHeight: UIScale.pt(180))
                        result(project).frame(minHeight: UIScale.pt(160))
                    }
                } else {
                    HSplitView {
                        editor.frame(minWidth: UIScale.pt(220))
                        result(project).frame(minWidth: UIScale.pt(220))
                    }
                }
            } else if model.load.isRunning {
                PageSkeleton(layout: .editor).padding(UIScale.pt(16))
            } else {
                ContentUnavailableView(
                    "Source unavailable", systemImage: "doc.questionmark",
                    description: Text("Retry loading the project above."))
            }
        }
    }

    private func controls(_ project: LaTeXProject) -> some View {
        PageHeader(project.name) {
            HStack(spacing: UIScale.pt(8)) {
                if project.location == .disk {
                    Button("Save & compile") { model.saveAndCompile() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.original == nil || model.busy || model.load.isRunning)
                } else {
                    Button(
                        project.pullRequest == nil ? "Create pull request" : "Update pull request"
                    ) {
                        model.submit()
                    }.buttonStyle(.borderedProminent).disabled(!model.canSubmit)
                    if project.pullRequest != nil {
                        Button("Review in Quinjet") {
                            showingReview = true
                            model.refreshReview()
                        }.disabled(model.busy)
                    }
                }
                Menu {
                    Button("Reload source") { Task { await model.reload() } }
                    if project.location == .disk {
                        Button("Reveal source in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: project.sourcePath)
                            ])
                        }
                    }
                    Button("Remove from library", role: .destructive) { model.remove() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(model.dirty || model.busy || model.load.isRunning)
            }
        } accessory: {
            Text(
                project.location == .disk
                    ? project.sourcePath
                    : "\(project.repository) · \(project.baseBranch) · \(project.sourcePath)"
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            PageSectionHeader("Source", subtitle: "UTF-8 · LaTeX")
            TextEditor(text: Binding(get: { model.source }, set: { model.source = $0 }))
                .font(.system(size: UIScale.pt(13), design: .monospaced))
                .scrollContentBackground(.hidden)
                .disabled(model.busy || model.load.isRunning)
                .accessibilityLabel("LaTeX source")
        }.padding(UIScale.pt(16))
    }

    @ViewBuilder private func result(_ project: LaTeXProject) -> some View {
        if project.location == .disk {
            VStack(spacing: UIScale.pt(12)) {
                EdithSegmentedPicker(
                    "Output", selection: $inspector, options: ["PDF", "Build log"], label: { $0 })
                if inspector == "Build log" {
                    ScrollView {
                        Text(
                            model.log.isEmpty
                                ? "Compile the source to see its build output." : model.log
                        )
                        .font(.system(size: UIScale.pt(12), design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if FileManager.default.fileExists(atPath: project.pdfURL.path) {
                    LaTeXPDF(url: project.pdfURL, generation: model.buildGeneration)
                    Button("Open PDF") { NSWorkspace.shared.open(project.pdfURL) }
                } else {
                    ContentUnavailableView(
                        "Ready to compile", systemImage: "doc.richtext",
                        description: Text("Save & compile creates a PDF beside your source file."))
                }
            }.padding(UIScale.pt(16))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                    PageSectionHeader(
                        "GitHub build", subtitle: "Source, review, and PDF builds stay on GitHub.")
                    Label("1. Edit your source", systemImage: "pencil")
                    Label("2. Create or update a pull request", systemImage: "arrow.triangle.pull")
                    Label(
                        "3. Review with Quinjet and squash merge", systemImage: "checkmark.circle")
                    Text(
                        "The pull request adds a Tectonic workflow. GitHub Actions compiles your document and attaches a PDF artifact to the run."
                    )
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                    if let review = model.review {
                        LaTeXChecks(review: review)
                        if review.pullRequest.state == "OPEN" {
                            LaTeXMergeOptions(model: model)
                        }
                    }
                    Link(
                        "Builds & PDF artifacts",
                        destination: URL(
                            string: "https://github.com/\(project.repository)/actions")!)
                    Text(
                        "No repository clone is created. Repository edits stay in memory until you submit them."
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(UIScale.pt(20))
            }
        }
    }
}

private struct LaTeXPDF: NSViewRepresentable {
    let url: URL
    let generation: UUID
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        let key = "\(url.path):\(generation)"
        guard view.identifier?.rawValue != key else { return }
        view.identifier = NSUserInterfaceItemIdentifier(key)
        view.document = PDFDocument(url: url)
    }
}

private struct LaTeXChecks: View {
    let review: LaTeXReview
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Link(
                "#\(review.pullRequest.number) · \(review.pullRequest.title)",
                destination: URL(string: review.pullRequest.url)!
            )
            .font(.edithText(.headline))
            Text(review.pullRequest.state.capitalized).font(.edithText(.caption)).foregroundStyle(
                .secondary)
            if review.checks.isEmpty {
                Text("Waiting for GitHub checks. Refresh to see the build.").font(
                    .edithText(.caption))
            }
            ForEach(Array(review.checks.enumerated()), id: \.offset) { _, check in
                HStack {
                    Image(systemName: check.status == "passed" ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(check.status == "passed" ? Color.green : Color.secondary)
                    Text("\(check.workflow) · \(check.name): \(check.status)").font(
                        .edithText(.caption))
                    if let url = URL(string: check.link), url.scheme == "https" {
                        Link("View run", destination: url)
                    }
                }
            }
        }
    }
}

private struct LaTeXReviewSheet: View {
    let model: LaTeXModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PageWorkspace {
            PageHeader("Quinjet review") {
                Button("Refresh") { model.refreshReview() }.disabled(model.busy)
                Button("Done") { dismiss() }
            }
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                if let review = model.review {
                    HStack {
                        LaTeXChecks(review: review)
                        Spacer()
                        if review.pullRequest.state == "OPEN" { LaTeXMergeOptions(model: model) }
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(review.diff).font(.system(size: UIScale.pt(12), design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Text(model.message ?? "Loading pull request with Quinjet…")
                        .font(.edithText(.subheadline))
                }
            }.padding(UIScale.pt(20))
        }
    }
}

private struct LaTeXMergeOptions: View {
    let model: LaTeXModel
    @State private var confirming = false
    var body: some View {
        Button("Merge options") { confirming = true }
            .disabled(model.dirty || model.busy)
            .confirmationDialog("Squash merge this pull request?", isPresented: $confirming) {
                Button("Squash merge and delete branch") { model.merge(automatically: false) }
                Button("Merge when checks pass") { model.merge(automatically: true) }
            } message: {
                Text("The source and compiler workflow will land on the repository's base branch.")
            }
    }
}
