import AppKit
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

    private let defaults: UserDefaults
    private var engineTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var projectsTask: Task<Void, Never>?
    private var recentTask: Task<Void, Never>?

    init(defaults: UserDefaults = SharedDefaults.store, loadsState: Bool = true) {
        self.defaults = defaults
        guard loadsState else { return }
        files = StudioLibraryStore.loadFiles(from: defaults)
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
        refreshEngines()
        refreshProjects()
        loadRecent()
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
        let added = StudioLibraryQuery.newItems(StudioLibraryStore.expand(urls), existing: files)
        guard !added.isEmpty else { return }
        files.insert(contentsOf: added, at: 0)
        persistFiles()
        if added.count == 1, let only = added.first {
            notice = "Added \(only.name)"
        } else if added.count > 1 {
            notice = "Added \(added.count) files"
        }
    }

    func remove(_ urls: Set<URL>) {
        files.removeAll { urls.contains($0.url) }
        selection.subtract(urls)
        persistFiles()
    }

    func clearMissing() {
        files.removeAll { facts[$0.url]?.exists == false }
        persistFiles()
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

    func newVideoProject() {
        route = .videoEditor([], project: nil)
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

    private func persistFiles() {
        StudioLibraryStore.saveFiles(files, to: defaults)
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
