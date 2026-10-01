import AppKit
import Combine
import EdithKit
import EdithStudio
import Foundation
import Observation

enum StudioTab: String, CaseIterable, Identifiable {
    case files
    case tools
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        case .tools: "Tools"
        case .projects: "Projects"
        }
    }
}

enum StudioRoute: Equatable {
    case home
    case tool(UUID)
    case imageEditor(URL)
    case pdfEditor(URL, StudioPDFEditorMode)
    case videoEditor([URL], project: URL?)
    case commandVideoEditor(String)
    case compare(URL, URL)
}

@MainActor
@Observable
final class StudioModel {
    var tab: StudioTab = .files
    var route: StudioRoute = .home
    var files: [StudioFileItem] = []
    var selection: Set<URL> = []
    var kindFilter: StudioKind?
    var toolQuery = ""
    var toolFamily: StudioKind?
    var facts: [URL: StudioFileFacts] = [:]
    var jobs: [StudioJob] = []
    var recent: [StudioRecentRun] = []
    var environment = StudioEnvironment()
    var installing: StudioEngine?
    var installLog: String?
    var message: String?
    var notice: String?
    var videoProjects: [VideoProject.Listing] = []
    var commandEditor: VideoEditorOpenBridge.Presentation?
    var workflows: [StudioWorkflow] = []
    var editingWorkflow: StudioWorkflowDraft?
    private var workflowsTask: Task<Void, Never>?

    private let defaults: UserDefaults
    private var engineTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var projectsTask: Task<Void, Never>?
    private var recentTask: Task<Void, Never>?
    private var librarySubscriptions: Set<AnyCancellable> = []
    private var libraryWatcher: FileSystemWatcher?
    private var libraryWatchPaths: [URL]?

    init(defaults: UserDefaults = SharedDefaults.store, loadsState: Bool = true) {
        self.defaults = defaults
        guard loadsState else { return }
        files = StudioLibraryStore.loadFiles(from: defaults)
        observeLibrary()
    }

    var visibleFiles: [StudioFileItem] { StudioLibraryQuery.visible(files, kind: kindFilter) }

    var kindsPresent: [StudioKind] { StudioLibraryQuery.kinds(in: files) }

    var selectedURLs: [URL] { StudioLibraryQuery.selected(files, in: selection) }

    var runningCount: Int {
        var count = 0
        for job in jobs where job.isRunning { count += 1 }
        return count
    }

    var destination: StudioDestination {
        let mode =
            StudioDestinationMode(
                rawValue: defaults.string(forKey: AppStorageKeys.Studio.destination) ?? "")
            ?? .original
        switch mode {
        case .original:
            return .nextToOriginal
        case .downloads:
            return .folder(
                FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
        case .folder:
            let path = defaults.string(forKey: AppStorageKeys.Studio.folder) ?? ""
            guard !path.isEmpty else { return .nextToOriginal }
            return .folder(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func start() {
        refreshLibrary()
        watchLibrary()
        refreshEngines()
        refreshProjects()
        loadRecent()
        loadWorkflows()
    }

    func refreshLibrary() {
        files = StudioLibraryStore.loadFiles(from: defaults)
        let known = StudioLibraryQuery.urls(files)
        selection.formIntersection(known)
        facts = facts.filter { known.contains($0.key) }
    }

    func observeLibrary() {
        guard librarySubscriptions.isEmpty else { return }
        DistributedNotificationCenter.default().publisher(for: IPC.Name.studioWorkflowsChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.loadWorkflows() }
            }.store(in: &librarySubscriptions)
        DistributedNotificationCenter.default().publisher(for: IPC.Name.studioMediaLibraryChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLibrary()
                    self?.loadRecent()
                }
            }.store(in: &librarySubscriptions)
        DistributedNotificationCenter.default().publisher(for: IPC.Name.videoProjectLibraryChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshProjects() }
            }.store(in: &librarySubscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshLibrary() }
            }.store(in: &librarySubscriptions)
    }

    func watchLibrary(paths: [URL]? = nil) {
        if let paths { libraryWatchPaths = paths }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates =
            libraryWatchPaths
            ?? [
                home.appendingPathComponent("Library/Preferences", isDirectory: true),
                DataRoot.support, VideoProject.openScreenLibraryURL.deletingLastPathComponent(),
            ]
        if libraryWatchPaths == nil {
            for project in videoProjects {
                candidates.append(project.url.deletingLastPathComponent())
            }
        }
        var unique = Set<String>()
        for candidate in candidates {
            var existing = candidate
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                existing.deleteLastPathComponent()
            }
            unique.insert(existing.path)
        }
        let current = Set(libraryWatcher?.watchedPaths ?? [])
        guard current != unique else { return }
        libraryWatcher?.stop()
        var directories: [URL] = []
        for path in unique { directories.append(URL(fileURLWithPath: path, isDirectory: true)) }
        libraryWatcher = FileSystemWatcher(paths: directories, debounce: 0.05, eventLatency: 0.05) {
            [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshLibrary()
                self?.refreshProjects()
                self?.loadRecent()
            }
        }
        libraryWatcher?.start()
    }

    func loadWorkflows() {
        workflowsTask?.cancel()
        workflowsTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { StudioWorkflowStore.load() }
                .value
            guard let self, !Task.isCancelled else { return }
            self.workflows = loaded
        }
    }

    func editWorkflow(_ workflow: StudioWorkflow?) {
        editingWorkflow = StudioWorkflowDraft(
            workflow: workflow ?? StudioWorkflow(name: "", steps: []))
    }

    func saveWorkflow(_ draft: StudioWorkflowDraft) {
        let workflow = draft.workflow
        do {
            try workflow.validate()
        } catch {
            draft.failure = error.localizedDescription
            return
        }
        if let index = workflows.firstIndex(where: { $0.id == workflow.id }) {
            workflows[index] = workflow
        } else {
            workflows.append(workflow)
        }
        StudioWorkflowStore.save(workflows)
        editingWorkflow = nil
        notice = "Saved \(workflow.name)"
    }

    func deleteWorkflow(_ workflow: StudioWorkflow) {
        workflows.removeAll { $0.id == workflow.id }
        StudioWorkflowStore.save(workflows)
    }

    func runWorkflow(_ workflow: StudioWorkflow, with urls: [URL]) {
        guard let tool = workflow.tool else {
            message = "This workflow has no tools."
            return
        }
        openRunner(tool, with: urls)
    }

    func refreshEngines() {
        engineTask?.cancel()
        engineTask = Task { [weak self] in
            let detected = await Task.detached(priority: .utility) {
                StudioEngineLocator.detect()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.environment = detected
        }
    }

    func refreshProjects() {
        projectsTask?.cancel()
        projectsTask = Task { [weak self] in
            let listings = await Task.detached(priority: .utility) {
                VideoProject.listProjects()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.videoProjects = listings
            if self.libraryWatcher != nil { self.watchLibrary() }
        }
    }

    func loadRecent() {
        recentTask?.cancel()
        recentTask = Task { [weak self] in
            let runs = await Task.detached(priority: .utility) {
                StudioLibraryStore.loadRecent()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.recent = runs
        }
    }

    func add(_ urls: [URL]) {
        let current = (try? StudioMediaLibrary.list(defaults: defaults)) ?? []
        let added = StudioLibraryQuery.newItems(StudioLibraryStore.expand(urls), existing: current)
        do {
            try StudioMediaLibrary.add(urls, defaults: defaults)
            refreshLibrary()
        } catch {
            message = error.localizedDescription
            return
        }
        if added.count == 1, let only = added.first {
            notice = "Added \(only.name)"
        } else if added.count > 1 {
            notice = "Added \(added.count) files"
        }
    }

    func remove(_ urls: Set<URL>) {
        do {
            try StudioMediaLibrary.remove(urls, defaults: defaults)
            refreshLibrary()
        } catch {
            message = error.localizedDescription
        }
    }

    func clearMissing() {
        let current = (try? StudioMediaLibrary.list(defaults: defaults)) ?? []
        var missing = Set<URL>()
        for item in current where !FileManager.default.fileExists(atPath: item.url.path) {
            missing.insert(item.url)
        }
        remove(missing)
    }

    func toggleSelection(_ url: URL) {
        if selection.contains(url) {
            selection.remove(url)
        } else {
            selection.insert(url)
        }
    }

    func selectAll() {
        selection = StudioLibraryQuery.urls(visibleFiles)
    }

    func loadFacts(for url: URL) async {
        guard facts[url] == nil else { return }
        let loaded = await Task.detached(priority: .utility) {
            await StudioInspector.facts(for: url)
        }.value
        facts[url] = loaded
    }

    func refreshFacts(for url: URL) {
        facts[url] = nil
        StudioThumbnails.shared.forget(url)
    }

    func open(_ tool: StudioTool, with urls: [URL]) {
        switch tool.style {
        case let .editor(kind, mode):
            guard let url = urls.first(where: tool.accepts) else {
                openRunner(tool, with: [])
                return
            }
            switch kind {
            case .image: route = .imageEditor(url)
            case .pdf: route = .pdfEditor(url, mode ?? .annotate)
            case .video:
                route = .videoEditor(StudioLibraryQuery.accepted(urls, by: tool), project: nil)
            }
        case .compare:
            let pdfs = StudioLibraryQuery.accepted(urls, by: tool)
            if pdfs.count >= 2 {
                route = .compare(pdfs[0], pdfs[1])
            } else {
                openRunner(tool, with: pdfs)
            }
        case .run:
            openRunner(tool, with: urls)
        }
    }

    func open(toolID: String, with urls: [URL]) {
        guard let tool = StudioCatalog.tool(toolID) else { return }
        open(tool, with: urls)
    }

    func quick(_ action: StudioQuickAction, for url: URL) {
        guard let tool = StudioCatalog.quickTool(action, for: url.studioKind) else { return }
        open(tool, with: [url])
    }

    func openRunner(_ tool: StudioTool, with urls: [URL]) {
        let job = StudioJob(tool: tool, inputs: urls)
        jobs.insert(job, at: 0)
        trimJobs()
        route = .tool(job.id)
    }

    func job(_ id: UUID) -> StudioJob? {
        jobs.first { $0.id == id }
    }

    func run(_ job: StudioJob) {
        job.run(destination: destination, environment: environment) { [weak self] finished in
            self?.record(finished)
        }
    }

    func rerun(_ job: StudioJob, with tool: StudioTool, inputs: [URL]) {
        let next = StudioJob(tool: tool, inputs: inputs, settings: nil)
        jobs.insert(next, at: 0)
        trimJobs()
        route = .tool(next.id)
        _ = job
    }

    func continueWith(_ tool: StudioTool, outputs: [URL]) {
        add(outputs)
        open(tool, with: outputs)
    }

    func goHome() {
        route = .home
    }

    func openVideoProject(_ url: URL) {
        route = .videoEditor([], project: url)
    }

    func openCommandProject(_ presentation: VideoEditorOpenBridge.Presentation) {
        commandEditor = presentation
        route = .commandVideoEditor(presentation.request.requestID)
    }

    func newVideoProject() {
        route = .videoEditor([], project: nil)
    }

    func trashProject(_ project: VideoProject.Listing) {
        Task { [weak self] in
            do {
                _ = try await VideoEditorService.trashProject(project.url)
                guard let self else { return }
                self.videoProjects.removeAll { $0.url == project.url }
                self.notice = "Moved \(project.title) to Trash"
                self.refreshProjects()
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    func record(_ job: StudioJob) {
        guard let result = job.result else { return }
        let outputs = StudioLibraryQuery.outputURLs(result)
        for output in outputs { refreshFacts(for: output) }
        recordSaved(toolID: job.tool.id, title: job.tool.title, outputs: outputs)
    }

    func recordSaved(toolID: String, title: String, outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        let entry = StudioRecentRun(
            id: UUID(), toolID: toolID, title: title, outputs: outputs, date: Date())
        recent.insert(entry, at: 0)
        if recent.count > StudioLibraryStore.recentLimit {
            recent.removeLast(recent.count - StudioLibraryStore.recentLimit)
        }
        StudioRecentWriter.shared.write(recent)
    }

    func install(_ engine: StudioEngine) {
        guard installing == nil else { return }
        installTask?.cancel()
        installing = engine
        installLog = nil
        let log: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor [weak self] in self?.installLog = line }
        }
        installTask = Task { [weak self] in
            let failure = await StudioEngineLocator.install(engine, log: log)
            guard let self, !Task.isCancelled else { return }
            self.installing = nil
            if let failure {
                self.message = failure
            } else {
                self.notice = "\(engine.title) is ready"
                self.refreshEngines()
            }
        }
    }

    func paste() {
        do {
            let urls = try StudioLibraryStore.pasteboardFiles(.general)
            guard !urls.isEmpty else {
                message = "The clipboard has no files, images or PDFs to add."
                return
            }
            add(urls)
        } catch {
            message = error.localizedDescription
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose images, PDFs, videos, audio or documents for Studio."
        panel.prompt = "Add"
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.add(panel.urls)
            }
        }
    }

    private func trimJobs() {
        guard jobs.count > 12 else { return }
        var kept: [StudioJob] = []
        for job in jobs where kept.count < 12 || job.isRunning { kept.append(job) }
        jobs = kept
    }
}

final class StudioRecentWriter: @unchecked Sendable {
    static let shared = StudioRecentWriter()

    private let queue = DispatchQueue(label: "studio.recent", qos: .utility)

    func write(_ runs: [StudioRecentRun]) {
        queue.async { StudioLibraryStore.saveRecent(runs) }
    }
}

enum StudioEngineLocator {
    static func detect() -> StudioEnvironment {
        var environment = StudioEnvironment.detect(
            path: CLIToolEnvironment.sanitized()["PATH"],
            resolve: { CLIToolEnvironment.executable(named: $0) })
        environment.temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdithStudio", isDirectory: true)
        return environment
    }

    static func spec(for engine: StudioEngine) -> CLIToolSpec {
        switch engine {
        case .ffmpeg: .ffmpeg
        case .qpdf: .qpdf
        }
    }

    static func install(
        _ engine: StudioEngine, log: @escaping @Sendable (String) -> Void
    ) async -> String? {
        do {
            try await ToolInstaller().install(spec(for: engine), log: log)
            return nil
        } catch {
            return "\(engine.title) could not be installed: \(error)"
        }
    }
}
