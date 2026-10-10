import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor @Observable
final class LaTeXModel {
    var projects: [LaTeXProject] = []
    var selectedID: UUID?
    var source = "" { didSet { if !remoteApplying, source != oldValue { publishDraft() } } }
    var original: LaTeXSource?
    var review: LaTeXReview?
    var pdfPreview: Data?
    var log = ""
    var buildGeneration = UUID()
    var editorRequest: UInt64 = 0
    var message: String?
    var busy = false
    var buildingPDF = false
    var hasRepositoryBuild = false
    var buildURL: URL?
    let load = ContentLoad()
    let editorControls = LaTeXEditorControls()
    let tools: LaTeXToolOwner
    let remote: LaTeXUIBridge?
    private var remoteGeneration = 0
    private var remoteTask: Task<Void, Never>?
    private var remoteApplying = false
    private var remoteActionRunning = false
    private var draftTask: Task<Void, Never>?
    private let service: LaTeXService
    private let store: LaTeXProjectStore
    private var operation: Task<Void, Never>?
    private var pdfID: UUID?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private(set) var isStopped = false

    init(
        service: LaTeXService = .live, store: LaTeXProjectStore = LaTeXProjectStore(),
        remote: LaTeXUIBridge? = nil
    ) {
        self.service = service
        self.store = store
        self.remote = remote
        tools = LaTeXToolOwner(remote: remote)
    }

    var selected: LaTeXProject? { projects.first { $0.id == selectedID } }
    var dirty: Bool { original != nil && source != original?.text }
    var canSubmit: Bool {
        guard let selected else { return false }
        return original != nil && selected.location == .github && !busy && !load.isRunning
    }

    func start() async {
        if let remote {
            guard !isStopped else { return }
            await refreshRemote(remote)
            if remoteTask == nil {
                remoteTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, !isStopped else { return }
                        await refreshRemote(remote)
                    }
                }
            }
            return
        }
        guard !isStopped, !load.hasContent else { return }
        let request = load.begin()
        do {
            projects = try store.load()
            if let draft = try store.loadDraft(),
                projects.contains(where: { $0.id == draft.projectID })
            {
                selectedID = draft.projectID; source = draft.text; original = draft.original
                editorRequest &+= 1
                message = "Unsaved edits restored. Save or discard them to continue."
            }
            load.complete(request, empty: projects.isEmpty)
        } catch {
            if !isStopped && !Task.isCancelled { load.fail(request, error: error) }
        }
    }

    func select(_ id: UUID) async {
        if remote != nil { await remoteAction(.init(action: "select", projectID: id)); return }
        guard !isStopped, !dirty, !busy else { return }
        stopFollowingBuild()
        selectedID = id
        hasRepositoryBuild = false
        source = ""
        original = nil
        review = nil
        pdfPreview = nil
        log = ""
        message = nil
        await reload()
    }

    func reload() async {
        if remote != nil {
            await remoteAction(.init(action: "reload", projectID: selectedID)); return
        }
        guard !isStopped, let project = selected, !dirty, !busy else { return }
        stopFollowingBuild()
        let request = load.begin(preservingContent: original != nil)
        do {
            var current = project
            if project.pullRequest != nil {
                let latest = try await service.review(project)
                if latest.pullRequest.state != "OPEN" {
                    current.reviewBranch = nil
                    current.pullRequest = nil
                    try replace(current)
                }
                review = latest
            }
            let result = try await service.load(current)
            let preview = current.location == .github ? try? await service.previewPDF(current) : nil
            var hasBuild =
                current.location == .github && (current.pullRequest != nil || preview != nil)
            if current.location == .github && !hasBuild {
                hasBuild = (try? await service.build(current)) != nil
            }
            guard !isStopped, load.isCurrent(request), selectedID == current.id else { return }
            source = result.text
            original = result
            pdfPreview = preview
            hasRepositoryBuild = hasBuild
            load.complete(request)
        } catch {
            if !isStopped && !Task.isCancelled { load.fail(request, error: error) }
        }
    }

    func add(_ project: LaTeXProject) async throws {
        if let remote {
            let next = try await remote.perform(.init(action: "add", project: project))
            guard !isStopped, !Task.isCancelled else { throw CancellationError() }
            applyRemote(next)
            return
        }
        guard !isStopped else { throw CancellationError() }
        let resolved = try await service.resolve(project)
        let content = try await service.load(resolved)
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        guard
            !projects.contains(where: {
                $0.location == resolved.location && $0.sourcePath == resolved.sourcePath
                    && $0.repository == resolved.repository && $0.baseBranch == resolved.baseBranch
            })
        else { throw LaTeXError.message("That project is already in your library.") }
        let next = projects + [resolved]
        try store.save(next)
        stopFollowingBuild()
        projects = next
        selectedID = resolved.id
        hasRepositoryBuild = resolved.pullRequest != nil
        original = content
        source = content.text
        review = nil
        pdfPreview = nil
        log = ""
        message = nil
        load.setContent()
    }

    func remove() {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(
                        action: "remove", projectID: self.selectedID,
                        revision: self.original?.revision, text: self.source))
            }; return
        }
        guard !isStopped, let selected, !dirty, !busy else { return }
        do {
            let next = projects.filter { $0.id != selected.id }
            try store.save(next)
            projects = next
            selectedID = nil
            hasRepositoryBuild = false
            stopFollowingBuild()
            source = ""
            original = nil
            review = nil
            load.setContent(empty: next.isEmpty)
        } catch { message = error.localizedDescription }
    }

    func discard() {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(
                        action: "discard", projectID: self.selectedID,
                        revision: self.original?.revision, text: self.source))
            }; return
        }
        guard !isStopped else { return }
        if let original { source = original.text }
        do { try store.saveDraft(nil) } catch { message = error.localizedDescription }
    }

    func requestEditor() {
        guard !isStopped, selectedID != nil else { return }
        editorRequest &+= 1
    }

    func saveAndCompile() {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(
                        action: "save", projectID: self.selectedID,
                        revision: self.original?.revision, text: self.source))
            }; return
        }
        guard let project = selected, let original, project.location == .disk else { return }
        let text = source
        perform {
            if text != original.text {
                try self.service.saveLocal(project, text: text, original: original)
                self.original = LaTeXSource(
                    text: text, revision: Data(text.utf8).base64EncodedString())
            }
            do {
                self.log = try await self.service.compileLocal(project)
                self.buildGeneration = UUID()
            } catch {
                self.log = error.localizedDescription
                throw error
            }
            self.message = "PDF compiled on disk."
        }
    }

    func submit() {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(
                        action: "submit", projectID: self.selectedID,
                        revision: self.original?.revision, text: self.source))
            }; return
        }
        guard let project = selected, let original, canSubmit else { return }
        stopFollowingBuild()
        let text = source
        let rebuildSavedBase = project.pullRequest == nil && !dirty
        perform {
            if rebuildSavedBase, try await self.service.build(project) != nil {
                self.hasRepositoryBuild = true
                _ = try await self.service.rebuild(project)
                self.pdfPreview = nil
                self.message = "Rebuilding PDF on GitHub."
                self.followBuild(project)
                return
            }
            var prepared = project
            if prepared.reviewBranch == nil {
                prepared.reviewBranch = "latex/\(UUID().uuidString.lowercased())"
            }
            try self.replace(prepared)
            let number = try await self.service.submit(prepared, text: text, original: original)
            var submitted = prepared
            submitted.pullRequest = number
            self.hasRepositoryBuild = true
            try self.replace(submitted)
            self.pdfPreview = nil
            self.original = try await self.service.load(submitted)
            self.message = "Pull request #\(number) saved. GitHub will compile the PDF."
            self.review = try await self.service.review(submitted)
            self.followBuild(submitted)
        }
    }

    func refreshPDF() {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(
                        action: "pdf", projectID: self.selectedID,
                        revision: self.original?.revision, text: self.source))
            }; return
        }
        guard let project = selected, !dirty else { return }
        perform {
            self.pdfPreview = try await self.service.previewPDF(project)
            self.buildGeneration = UUID()
            self.message =
                self.pdfPreview == nil
                ? "No PDF for this revision yet. Check the GitHub build, then refresh."
                : "PDF loaded from GitHub."
        }
    }

    func refreshReview() {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(
                        action: "review", projectID: self.selectedID,
                        revision: self.original?.revision, text: self.source))
            }; return
        }
        guard let project = selected else { return }
        perform { self.review = try await self.service.review(project) }
    }

    private func followBuild(_ project: LaTeXProject) {
        stopFollowingBuild()
        guard !isStopped, jobs.count < 16 else { return }
        buildingPDF = true
        let id = UUID()
        pdfID = id
        jobs[id] = Task { [weak self] in
            defer { self?.jobs[id] = nil }
            for _ in 0..<60 {
                do {
                    guard !Task.isCancelled, let self, self.selectedID == project.id else { return }
                    if let build = try await self.service.build(project) {
                        guard !Task.isCancelled, self.selectedID == project.id else { return }
                        self.buildURL = URL(string: build.html_url)
                        self.hasRepositoryBuild = true
                        if build.status == "completed" {
                            guard build.conclusion == "success" else {
                                self.buildingPDF = false
                                self.message =
                                    "PDF build failed on GitHub. Open the build for details."
                                return
                            }
                            if let pdf = try await self.service.previewPDF(
                                project, buildID: build.id)
                            {
                                guard !Task.isCancelled, self.selectedID == project.id else {
                                    return
                                }
                                self.pdfPreview = pdf
                                self.buildGeneration = UUID()
                                self.buildingPDF = false
                                self.message = "PDF compiled on GitHub."
                                return
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled { self?.message = error.localizedDescription }
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
            self?.buildingPDF = false
            self?.message = "The PDF build is taking longer. Open the build or refresh the PDF."
        }
    }

    private func stopFollowingBuild() {
        if let pdfID { jobs[pdfID]?.cancel() }
        pdfID = nil
        buildingPDF = false
        buildURL = nil
    }

    func merge(automatically: Bool) {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(
                        action: "merge", projectID: self.selectedID,
                        revision: self.original?.revision, text: self.source,
                        automatically: automatically))
            }; return
        }
        guard let project = selected, !dirty else { return }
        perform {
            try await self.service.merge(project, automatically: automatically)
            self.message =
                automatically
                ? "Squash merge scheduled after required checks pass."
                : "Pull request squash merged."
            if !automatically {
                self.stopFollowingBuild()
                var finished = project
                finished.reviewBranch = nil
                finished.pullRequest = nil
                try self.replace(finished)
                let content = try await self.service.load(finished)
                self.original = content
                self.source = content.text
                self.pdfPreview = nil
                self.followBuild(finished)
            }
            self.review = try await self.service.review(project)
        }
    }

    private func replace(_ project: LaTeXProject) throws {
        let next = projects.map { $0.id == project.id ? project : $0 }
        try store.save(next)
        projects = next
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isStopped, !busy else { return }
        busy = true
        message = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await action()
                if !dirty { try store.saveDraft(nil) }
            } catch {
                if !isStopped && !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
    @discardableResult
    func launch(_ action: @escaping @MainActor () async -> Void) -> Bool {
        guard !isStopped, jobs.count < 16 else { return false }
        let id = UUID()
        jobs[id] = Task { [weak self] in
            defer { self?.jobs[id] = nil }
            guard !Task.isCancelled, self?.isStopped == false else { return }
            await action()
        }
        return true
    }

    func shutdown() async {
        if remote == nil, dirty, let selectedID, let original {
            do {
                try store.saveDraft(.init(projectID: selectedID, text: source, original: original))
            } catch { message = error.localizedDescription }
        }
        isStopped = true
        remoteGeneration &+= 1
        remoteTask?.cancel(); remoteTask = nil
        draftTask?.cancel(); draftTask = nil
        operation?.cancel()
        for job in jobs.values { job.cancel() }
        if let operation { await operation.value }
        for job in Array(jobs.values) { await job.value }
        operation = nil; jobs.removeAll(); pdfID = nil
        await tools.shutdown()
        editorControls.shutdown()
        load.reset(); editorRequest = 0
        projects.removeAll(); selectedID = nil; source = ""; original = nil
        review = nil; pdfPreview = nil; log = ""; message = nil
        busy = false; buildingPDF = false; hasRepositoryBuild = false; buildURL = nil
    }

    func settleOperation() async { await operation?.value }

    func revealSource() {
        if remote != nil {
            launch { await self.remoteAction(.init(action: "reveal", projectID: self.selectedID)) }
        } else if let selected {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: selected.sourcePath)
            ])
        }
    }

    func openPDF(save: Bool) {
        if remote != nil {
            launch {
                await self.remoteAction(
                    .init(action: save ? "savePDF" : "openPDF", projectID: self.selectedID))
            }
        } else {
            do { try deliverPDF(save: save) } catch { message = error.localizedDescription }
        }
    }
    func deliverPDF(save: Bool) throws {
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil,
            let project = selected
        else { throw ExtensionPeerError.invalidRequest }
        let bytes = project.location == .disk ? try Data(contentsOf: project.pdfURL) : pdfPreview
        guard let bytes else { throw ExtensionPeerError.unavailable }
        if save {
            let panel = NSSavePanel(); panel.nameFieldStringValue = project.pdfURL.lastPathComponent
            if panel.runModal() == .OK, let url = panel.url {
                try bytes.write(to: url, options: .atomic)
            }
        } else if project.location == .disk {
            NSWorkspace.shared.open(project.pdfURL)
        } else {
            let directory = ExtensionData.root.appendingPathComponent(
                "PDFPreviews", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(project.id.uuidString + ".pdf")
            try bytes.write(to: url, options: .atomic); NSWorkspace.shared.open(url)
        }
    }

    private func publishDraft() {
        guard let remote, !isStopped, let id = selectedID, let original else { return }
        draftTask?.cancel()
        let request = LaTeXUIAction(
            action: "draft", projectID: id, revision: original.revision, text: source)
        draftTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                _ = try await remote.perform(request)
            } catch { if !Task.isCancelled { self?.message = error.localizedDescription } }
        }
    }

    private func refreshRemote(_ remote: LaTeXUIBridge) async {
        guard !remoteActionRunning else { return }
        remoteGeneration &+= 1
        let generation = remoteGeneration
        let request = load.begin(preservingContent: load.hasContent)
        do {
            let value = try await remote.snapshot()
            guard !isStopped, !Task.isCancelled, generation == remoteGeneration else { return }
            applyRemote(value, retainingDraft: dirty)
            load.complete(request, empty: projects.isEmpty)
        } catch {
            if !isStopped, !Task.isCancelled, generation == remoteGeneration {
                load.fail(request, error: error)
            }
        }
    }

    private func remoteAction(_ action: LaTeXUIAction) async {
        guard let remote, !isStopped, !busy else { return }
        remoteGeneration &+= 1
        let generation = remoteGeneration
        draftTask?.cancel()
        busy = true
        remoteActionRunning = true
        defer { remoteActionRunning = false }
        do {
            let value = try await remote.perform(action)
            guard !isStopped, !Task.isCancelled, generation == remoteGeneration else { return }
            applyRemote(value)
        } catch {
            if !isStopped, !Task.isCancelled, generation == remoteGeneration {
                message = error.localizedDescription
            }
        }
    }

    private func applyRemote(_ value: LaTeXUISnapshot, retainingDraft: Bool = false) {
        remoteApplying = true
        defer { remoteApplying = false }
        projects = value.projects
        if !retainingDraft || selectedID != value.selectedID
            || original?.revision != value.original?.revision
        {
            selectedID = value.selectedID
            source = value.source
            original = value.original
        }
        review = value.review; pdfPreview = value.pdfPreview
        editorRequest = value.editorRequest
        log = value.log; buildGeneration = value.buildGeneration
        busy = value.busy; buildingPDF = value.buildingPDF
        hasRepositoryBuild = value.hasRepositoryBuild; buildURL = value.buildURL
        message = value.message
        tools.apply(value.tools)
        load.setContent(empty: projects.isEmpty)
    }
}
