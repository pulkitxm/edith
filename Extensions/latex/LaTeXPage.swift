import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import PDFKit
import SwiftUI

struct LaTeXPage: View {
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var editing = false
    @State private var adding = false
    @State private var showingReview = false
    @State private var showingTools = false
    @State private var inspector = "PDF"
    @State private var layout = "Split"
    let model: LaTeXModel
    init(model: LaTeXModel, opensEditor: Bool = false) {
        self.model = model
        _editing = State(initialValue: opensEditor || model.editorRequest > 0)
    }
    private var editorControls: LaTeXEditorControls { model.editorControls }

    var body: some View {
        Group {
            if showingReview {
                LaTeXReviewWorkspace(model: model, onClose: { showingReview = false })
            } else if editing, let project = model.selected {
                PageWorkspace {
                    controls(project)
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
        .edithSheet(isPresented: $showingTools, dismissible: nil) {
            LaTeXToolsPage(owner: model.tools).frame(
                width: UIScale.pt(620), height: UIScale.pt(530))
        }
        .onChange(of: model.editorRequest) { _, generation in
            if generation > 0 { editing = true }
        }
        .onChange(of: model.selectedID) { _, id in
            inspector = "PDF"; if id == nil { editing = false }
        }
    }

    private var projectsPage: some View {
        PageScaffold {
            PageHeader("LaTeX projects") {
                Button("Tools", systemImage: "wrench.and.screwdriver") { showingTools = true }
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
                layout: .cards, retry: { model.launch { await model.start() } }
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
            model.launch {
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
        .buttonStyle(.edith(.borderless))
        .disabled(model.busy || model.load.isRunning)
    }

    private func workspace(_ project: LaTeXProject) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(10)) {
                if model.busy || model.load.isRunning || model.buildingPDF {
                    LoadingIndicator()
                    Text(
                        model.busy
                            ? "Saving and compiling…"
                            : model.buildingPDF ? "Building PDF on GitHub…" : "Loading source…")
                } else if model.dirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Saved", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let message = model.message ?? model.load.errorMessage {
                    Text(message).foregroundStyle(.secondary).lineLimit(1).help(message)
                }
                Spacer(minLength: 0)
                if model.dirty {
                    Button("Discard edits") { model.discard() }.disabled(model.busy)
                }
                if model.load.errorMessage != nil {
                    Button("Retry") { model.launch { await model.reload() } }.disabled(model.dirty)
                }
            }
            .font(.edithText(.caption))
            .frame(height: UIScale.pt(32))
            .pageGutter(compact)
            Divider()
            if model.original != nil {
                if layout == "Source" {
                    editor
                } else if layout == "PDF" {
                    result(project)
                } else if compact {
                    VSplitView {
                        editor.frame(minHeight: UIScale.pt(180))
                        result(project).frame(minHeight: UIScale.pt(160))
                    }
                } else {
                    HSplitView {
                        editor.frame(minWidth: UIScale.pt(280))
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

    private func save() {
        if model.selected?.location == .disk { model.saveAndCompile() } else { model.submit() }
    }

    private func controls(_ project: LaTeXProject) -> some View {
        PageSectionHeader(
            project.name,
            subtitle: project.location == .disk
                ? project.sourcePath
                : "\(project.repository) · \(project.baseBranch) · \(project.sourcePath)"
        ) {
            HStack(spacing: UIScale.pt(8)) {
                Button {
                    editing = false
                } label: {
                    Label("Projects", systemImage: "chevron.left")
                }.disabled(model.dirty || model.busy)
                if project.location == .disk {
                    Button("Save & compile") { model.saveAndCompile() }
                        .buttonStyle(.edith(.primary))
                        .keyboardShortcut("s", modifiers: .command)
                        .help("Save and compile (⌘S)")
                        .disabled(model.original == nil || model.busy || model.load.isRunning)
                } else {
                    Button(
                        !model.hasRepositoryBuild
                            ? "Create pull request" : model.dirty ? "Save & compile" : "Recompile"
                    ) {
                        model.submit()
                    }
                    .buttonStyle(.edith(.primary))
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save to the pull request and compile on GitHub (⌘S)")
                    .disabled(!model.canSubmit)
                    if project.pullRequest != nil {
                        Button("Review in Quinjet") {
                            showingReview = true
                            model.refreshReview()
                        }.disabled(model.busy)
                    }
                }
                Menu {
                    Picker("Layout", selection: $layout) {
                        Text("Source & PDF").tag("Split")
                        Text("Source only").tag("Source")
                        Text("PDF only").tag("PDF")
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }.help("Editor layout").accessibilityLabel("Editor layout")
                Menu {
                    Button("Reload source") { model.launch { await model.reload() } }
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
        }
        .pageGutter(compact)
        .padding(.vertical, UIScale.pt(14))
    }

    private var editor: some View {
        @Bindable var editorControls = model.editorControls
        return VStack(alignment: .leading, spacing: 0) {
            WrapHStack(spacing: UIScale.pt(12)) {
                Label(
                    model.selected.map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent }
                        ?? "Source", systemImage: "doc.text"
                )
                .font(.edithText(.subheadline))
                .lineLimit(1).truncationMode(.middle)
                HStack(spacing: UIScale.pt(12)) {
                    Button {
                        editorControls.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }.help("Undo (⌘Z)").disabled(!editorControls.canUndo)
                    Button {
                        editorControls.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }.help("Redo (⇧⌘Z)").disabled(!editorControls.canRedo)
                    Divider().frame(height: UIScale.pt(16))
                    Button {
                        editorControls.find()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }.help("Find and replace (⌘F)").keyboardShortcut("f", modifiers: .command)
                    Menu {
                        Button("Bold (⌘B)") { editorControls.command("bold") }
                        Button("Italic (⌘I)") { editorControls.command("italic") }
                        Button("Section") { editorControls.command("section") }
                        Button("Equation") { editorControls.command("equation") }
                        Button("List") { editorControls.command("list") }
                    } label: {
                        Image(systemName: "textformat")
                    }.help("Insert LaTeX").accessibilityLabel("Insert LaTeX")
                    Menu {
                        Toggle("Wrap lines", isOn: $editorControls.wrapsLines)
                        Picker("Text size", selection: $editorControls.fontSize) {
                            ForEach([12, 13, 14, 15, 16, 18, 20], id: \.self) { size in
                                Text("\(size) pt").tag(Double(size))
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }.help("Editor options").accessibilityLabel("Editor options")
                }.disabled(model.busy || model.load.isRunning)
            }
            .buttonStyle(.edith(.toolbar))
            .tint(.primary)
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(8))
            Divider()
            LaTeXSourceEditor(
                text: Binding(get: { model.source }, set: { model.source = $0 }),
                controls: editorControls, dark: scheme == .dark,
                editable: !model.busy && !model.load.isRunning,
                documentID: model.selectedID?.uuidString ?? "",
                onSave: { save() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("LaTeX · UTF-8 · \(model.selected?.compiler.title ?? "")").font(
                    .edithText(.caption)
                ).foregroundStyle(.secondary)
                Spacer()
                Text("Ln \(editorControls.line), Col \(editorControls.column)").font(
                    .edithText(.caption)
                ).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(28))
        }
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
                    LaTeXPDFPane(url: project.pdfURL, generation: model.buildGeneration)
                } else {
                    ContentUnavailableView(
                        "Ready to compile", systemImage: "doc.richtext",
                        description: Text("Save & compile creates a PDF beside your source file.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.padding(UIScale.pt(16))
        } else {
            VStack(spacing: UIScale.pt(12)) {
                EdithSegmentedPicker(
                    "Output", selection: $inspector, options: ["PDF", "Build & review"],
                    label: { $0 })
                if inspector == "PDF" {
                    HStack {
                        Text("GitHub PDF").font(.edithText(.headline))
                        Spacer()
                        Button("Refresh PDF") { model.refreshPDF() }.disabled(
                            model.busy || model.dirty)
                    }
                    if let url = model.buildURL { Link("View PDF build", destination: url) }
                    if let data = model.pdfPreview {
                        LaTeXPDFPane(data: data, generation: model.buildGeneration)
                    } else {
                        ContentUnavailableView(
                            model.buildingPDF
                                ? "Building PDF"
                                : model.hasRepositoryBuild ? "Ready to recompile" : "GitHub build",
                            systemImage: "doc.richtext",
                            description: Text(
                                model.hasRepositoryBuild
                                    ? "Recompile builds the saved revision on GitHub. The PDF opens here when it finishes."
                                    : "Create a pull request to build this document on GitHub. The PDF opens here when it finishes."
                            )
                        ).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Link(
                        "Builds & PDF artifacts",
                        destination: URL(
                            string: "https://github.com/\(project.repository)/actions")!)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                            PageSectionHeader(
                                "GitHub build",
                                subtitle: "Source, review, and PDF builds stay on GitHub.")
                            Label("1. Edit your source", systemImage: "pencil")
                            Label(
                                "2. Create or update a pull request",
                                systemImage: "arrow.triangle.pull")
                            Label(
                                "3. Review with Quinjet and squash merge",
                                systemImage: "checkmark.circle")
                            Text(
                                "The pull request adds a compiler workflow. GitHub Actions compiles your document and attaches a PDF artifact to the run."
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
            }.padding(UIScale.pt(16))
        }
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

private struct LaTeXReviewWorkspace: View {
    let model: LaTeXModel
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var tab = "Changes"
    @State private var format = "Unified"
    var body: some View {
        PageWorkspace {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                PageSectionHeader("Quinjet review", subtitle: model.selected?.repository ?? "") {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshReview() }
                        .disabled(model.busy)
                    if model.review?.pullRequest.state == "OPEN" { LaTeXMergeOptions(model: model) }
                    Button("Back to editor", systemImage: "chevron.left", action: onClose)
                }
                if let review = model.review {
                    HStack(alignment: .top, spacing: UIScale.pt(12)) {
                        Text(review.pullRequest.state.capitalized)
                            .font(.edithText(.caption).weight(.semibold))
                            .foregroundStyle(
                                review.pullRequest.state == "OPEN" ? Color.green : .secondary
                            )
                            .padding(.horizontal, UIScale.pt(10)).padding(.vertical, UIScale.pt(5))
                            .background(.quaternary, in: Capsule())
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            Text("#\(review.pullRequest.number) · \(review.pullRequest.title)")
                                .font(.edithText(.headline)).textSelection(.enabled)
                            Text(
                                "\(model.selected?.reviewBranch ?? "Review branch") → \(model.selected?.baseBranch ?? "Base branch")"
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = URL(string: review.pullRequest.url), url.scheme == "https" {
                            Link("GitHub", destination: url).font(.edithText(.subheadline))
                        }
                    }
                    HStack {
                        EdithSegmentedPicker(
                            "Review", selection: $tab, options: ["Changes", "Checks"], label: { $0 }
                        ).frame(width: UIScale.pt(240))
                        Spacer()
                        if tab == "Changes" {
                            EdithSegmentedPicker(
                                "Diff layout", selection: $format, options: ["Unified", "Split"],
                                label: { $0 }
                            ).frame(width: UIScale.pt(180))
                            Button("Copy patch", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(review.diff, forType: .string)
                            }
                        }
                    }
                }
                if let message = model.message {
                    Text(message).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }.padding(UIScale.pt(16))
            Divider()
        } content: {
            if let review = model.review {
                if tab == "Changes" {
                    QuinjetDiffView(
                        patch: review.diff, split: format == "Split", dark: scheme == .dark)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                            PageSectionHeader(
                                "Checks",
                                subtitle: "\(review.checks.count) checks for this revision")
                            if review.checks.isEmpty {
                                Text("No checks reported for this pull request.").foregroundStyle(
                                    .secondary)
                            }
                            ForEach(Array(review.checks.enumerated()), id: \.offset) { _, check in
                                HStack(spacing: UIScale.pt(12)) {
                                    Image(
                                        systemName: check.status == "passed"
                                            ? "checkmark.circle.fill"
                                            : check.status == "failed"
                                                ? "xmark.circle.fill" : "clock"
                                    )
                                    .foregroundStyle(
                                        check.status == "passed"
                                            ? Color.green
                                            : check.status == "failed" ? .red : .secondary)
                                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                        Text(check.name).font(.edithText(.headline))
                                        Text("\(check.workflow) · \(check.status)").font(
                                            .edithText(.caption)
                                        ).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let url = URL(string: check.link), url.scheme == "https" {
                                        Link("View run", destination: url)
                                    }
                                }.padding(UIScale.pt(14)).background(
                                    .quaternary, in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                            }
                        }.padding(UIScale.pt(20))
                    }
                }
            } else {
                PageLoading(
                    state: model.busy ? .loading : .empty,
                    title: "Pull request review", message: model.message ?? "Loading review…",
                    layout: .cards, retry: { model.refreshReview() }
                ) { EmptyView() }
            }
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
