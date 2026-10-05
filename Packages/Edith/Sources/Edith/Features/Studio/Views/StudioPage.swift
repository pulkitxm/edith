import AppKit
import EdithKit
import EdithStudio
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class StudioPageStorage: ObservableObject {
    private let suppliedModel: StudioModel?
    private var createdModel: StudioModel?

    init(model: StudioModel? = nil) {
        suppliedModel = model
    }

    var model: StudioModel {
        if let suppliedModel { return suppliedModel }
        if let createdModel { return createdModel }
        let model = StudioModel()
        createdModel = model
        return model
    }

    deinit {
        if let model = createdModel { Task { @MainActor in model.closeEditors() } }
    }
}

struct StudioPage: View {
    private let suppliedModel: StudioModel?
    @StateObject private var storage: StudioPageStorage
    @Environment(\.windowSessionOwner) private var sessionOwner
    private var model: StudioModel { suppliedModel ?? sessionOwner?.studio ?? storage.model }
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    @MainActor init(model: StudioModel? = nil) {
        suppliedModel = model
        _storage = StateObject(wrappedValue: StudioPageStorage(model: model))
    }

    var body: some View {
        @Bindable var model = model
        return
            content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageSurface()
            .navigationRoute("editor", selection: editorBinding, isValid: editorIsValid)
            .navigationRoute("tab", selection: $model.tab)
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
            .edithSheet(
                isPresented: Binding(
                    get: { model.editingWorkflow != nil },
                    set: { if !$0 { model.editingWorkflow = nil } }),
                dismissible: false
            ) {
                if let draft = model.editingWorkflow {
                    StudioWorkflowEditor(model: model, draft: draft)
                }
            }
            .pageTask {
                model.start()
            }
            .onChange(of: VideoEditorOpenBridge.shared.pending?.request.requestID, initial: true) {
                _, _ in
                guard sessionOwner?.acceptsCommandVideo != false else { return }
                if let presentation = VideoEditorOpenBridge.shared.pending {
                    model.openCommandProject(presentation)
                }
            }
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { model.route.navigationToken },
            set: { model.route = StudioRoute(navigationToken: $0) ?? .home })
    }

    private func editorIsValid(_ token: String) -> Bool {
        guard let route = StudioRoute(navigationToken: token) else { return false }
        switch route {
        case .home:
            return true
        case let .tool(id):
            return model.job(id) != nil
        case let .imageEditor(url), let .pdfEditor(url, _):
            return FileManager.default.fileExists(atPath: url.path)
        case let .videoEditor(_, project):
            guard let project else { return false }
            return FileManager.default.fileExists(atPath: project.path)
        case .commandVideoEditor:
            return model.commandEditor != nil
        case let .compare(original, revised):
            return FileManager.default.fileExists(atPath: original.path)
                && FileManager.default.fileExists(atPath: revised.path)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.route {
        case .home:
            StudioHome(model: model)
        case let .tool(id):
            if let job = model.job(id) {
                StudioRunnerView(model: model, job: job).presenterCover(.studio)
            } else {
                StudioHome(model: model)
            }
        case let .imageEditor(url):
            StudioImageEditorView(model: model, url: url).presenterCover(.studio)
                .id(url)
        case let .pdfEditor(url, mode):
            StudioPDFEditorView(model: model, url: url, mode: mode).presenterCover(.studio)
                .id(url)
        case let .videoEditor(media, project):
            StudioVideoHost(model: model, media: media, project: project).presenterCover(.studio)
                .id(model.route.navigationToken)
        case let .commandVideoEditor(requestID):
            if let presentation = model.commandEditor, presentation.request.requestID == requestID {
                StudioVideoHost(
                    model: model, media: [],
                    project: URL(fileURLWithPath: presentation.request.path), command: presentation
                )
                .presenterCover(.studio)
                .id(requestID)
            }
        case let .compare(original, revised):
            StudioCompareView(model: model, original: original, revised: revised)
                .presenterCover(.studio)
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
        PageWorkspace {
            PageHeader(
                title: { Text("Studio") },
                trailing: { StudioHeaderActions(model: model) },
                accessory: {
                    let layout =
                        compact
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(8)))
                        : AnyLayout(HStackLayout(spacing: UIScale.pt(12)))
                    layout {
                        StudioTabBar(model: model)
                            .frame(maxWidth: UIScale.pt(250))
                        Text(subtitle)
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                })
        } content: {
            switch model.tab {
            case .files: StudioFilesView(model: model).presenterCover(.studio)
            case .tools: StudioToolsView(model: model)
            case .projects: StudioProjectsView(model: model).presenterCover(.studio)
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

    var body: some View {
        EdithSegmentedPicker(
            "Studio tab",
            selection: Binding(get: { model.tab }, set: { model.tab = $0 }),
            options: StudioTab.allCases, label: { $0.title },
            shortcut: { tab in
                KeyboardShortcut(
                    KeyEquivalent(
                        Character(String((StudioTab.allCases.firstIndex(of: tab) ?? 0) + 1))),
                    modifiers: .command)
            })
    }
}

struct StudioHeaderActions: View {
    let model: StudioModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HStack(spacing: UIScale.pt(compact ? 4 : 8)) {
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
                .help("Import a scan or photo from your iPhone or iPad")
            Button {
                model.paste()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: UIScale.pt(14), weight: .medium))
                    .frame(width: UIScale.pt(16), height: UIScale.pt(16))
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
