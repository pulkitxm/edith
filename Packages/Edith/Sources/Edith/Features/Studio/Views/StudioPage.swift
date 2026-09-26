import AppKit
import EdithKit
import EdithStudio
import SwiftUI
import UniformTypeIdentifiers

struct StudioPage: View {
    @State private var model: StudioModel
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    @MainActor init(model: StudioModel? = nil) {
        _model = State(initialValue: model ?? StudioModel())
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DashSkin.paper(scheme == .dark))
            .navigationTitle("Studio")
            .dropDestination(for: URL.self) { urls, _ in
                accept(urls)
                return !urls.isEmpty
            } isTargeted: {
                dropTargeted = $0
            }
            .overlay {
                if dropTargeted, acceptsDrops {
                    StudioDropOverlay()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    StudioToast(text: notice)
                        .padding(.bottom, UIScale.pt(18))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(2.4))
                            if model.notice == notice { model.notice = nil }
                        }
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.notice)
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
            .alert(
                "Studio",
                isPresented: Binding(
                    get: { model.message != nil }, set: { if !$0 { model.message = nil } })
            ) {
                Button("OK") { model.message = nil }
            } message: {
                Text(model.message ?? "")
            }
            .sheet(
                isPresented: Binding(
                    get: { model.editingWorkflow != nil },
                    set: { if !$0 { model.editingWorkflow = nil } })
            ) {
                if let draft = model.editingWorkflow {
                    StudioWorkflowEditor(model: model, draft: draft)
                }
            }
            .task {
                guard automaticActionsEnabled else { return }
                model.start()
            }
    }

    @ViewBuilder private var content: some View {
        switch model.route {
        case .home:
            StudioHome(model: model)
        case let .tool(id):
            if let job = model.job(id) {
                StudioRunnerView(model: model, job: job)
            } else {
                StudioHome(model: model)
            }
        case let .imageEditor(url):
            StudioImageEditorView(model: model, url: url)
        case let .pdfEditor(url, mode):
            StudioPDFEditorView(model: model, url: url, mode: mode)
        case let .videoEditor(media, project):
            StudioVideoHost(model: model, media: media, project: project)
        case let .compare(original, revised):
            StudioCompareView(model: model, original: original, revised: revised)
        }
    }

    private var acceptsDrops: Bool {
        switch model.route {
        case .home, .tool: true
        default: false
        }
    }

    private func accept(_ urls: [URL]) {
        let files = StudioLibraryStore.expand(urls)
        guard !files.isEmpty, acceptsDrops else { return }
        model.add(files)
        if case let .tool(id) = model.route, let job = model.job(id) {
            job.add(files)
        }
    }
}

struct StudioDropOverlay: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            DashSkin.accent(scheme == .dark).opacity(0.08)
            RoundedRectangle(cornerRadius: UIScale.pt(18))
                .strokeBorder(
                    DashSkin.accent(scheme == .dark),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(UIScale.pt(14))
            VStack(spacing: UIScale.pt(8)) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: UIScale.pt(34), weight: .light))
                Text("Drop to add to Studio")
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
            }
            .foregroundStyle(DashSkin.accent(scheme == .dark))
        }
    }
}

struct StudioHome: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: { Text("Studio") },
                trailing: { StudioHeaderActions(model: model) },
                accessory: {
                    HStack(spacing: UIScale.pt(12)) {
                        StudioTabBar(model: model)
                        Text(subtitle)
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                })
            switch model.tab {
            case .files: StudioFilesView(model: model)
            case .tools: StudioToolsView(model: model)
            case .projects: StudioProjectsView(model: model)
            }
        }
    }

    private var subtitle: String {
        switch model.tab {
        case .files: "Everything you drop in stays on this Mac."
        case .tools:
            "\(StudioCatalog.tools.count) tools for PDFs, images, video, audio and documents."
        case .projects: "Video projects and the files Studio made for you."
        }
    }
}

struct StudioTabBar: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(2)) {
            ForEach(StudioTab.allCases) { tab in
                Button {
                    model.tab = tab
                } label: {
                    Text(tab.title)
                        .font(
                            .system(
                                size: UIScale.pt(12.5),
                                weight: model.tab == tab ? .semibold : .regular)
                        )
                        .padding(.horizontal, UIScale.pt(12))
                        .padding(.vertical, UIScale.pt(5))
                        .background(
                            model.tab == tab ? DashSkin.paper2(scheme == .dark) : Color.clear,
                            in: RoundedRectangle(cornerRadius: UIScale.pt(7))
                        )
                        .shadow(color: .black.opacity(model.tab == tab ? 0.08 : 0), radius: 1, y: 1)
                        .edithButtonTarget(.borderless)
                }
                .buttonStyle(.edith(.borderless))
                .keyboardShortcut(
                    KeyEquivalent(
                        Character(String((StudioTab.allCases.firstIndex(of: tab) ?? 0) + 1))),
                    modifiers: .command
                )
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
            }
        }
        .padding(UIScale.pt(3))
        .background(
            DashSkin.grid(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}

struct StudioHeaderActions: View {
    let model: StudioModel

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            if model.runningCount > 0 {
                Menu {
                    ForEach(model.jobs) { job in
                        if job.isRunning {
                            Button("\(job.tool.title) · \(Int(job.progress * 100))%") {
                                model.route = .tool(job.id)
                            }
                        }
                    }
                } label: {
                    Label("\(model.runningCount) running", systemImage: "gearshape.2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            StudioScanButton { urls in model.add(urls) }
                .frame(width: UIScale.pt(30), height: UIScale.pt(28))
                .help("Import a scan or photo from your iPhone or iPad")
            Button {
                model.paste()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.edith(.secondary))
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .help("Add files or images from the clipboard (⇧⌘V)")
            Button {
                model.chooseFiles()
            } label: {
                Label("Add files", systemImage: "plus")
            }
            .buttonStyle(.edith(.primary))
            .keyboardShortcut("o", modifiers: .command)
            .help("Choose files to add (⌘O)")
        }
    }
}
