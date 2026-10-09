import AppKit
import EdithDocsWorker
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionDocuments
import Observation

struct DocsScrollRequest: Equatable {
    let anchor: String?
    let serial: Int
}

@MainActor @Observable
final class DocsBrowser {

    private(set) var library: DocsLibrary?
    private(set) var location = DocsLocation(path: DocsLibrary.indexPath)
    private(set) var scroll = DocsScrollRequest(anchor: nil, serial: 0)
    private(set) var revealSerial = 0
    private(set) var flashAnchor: String?
    private(set) var answer: DocsAnswer?
    private(set) var asking = false
    private(set) var resultsVisible = false
    private var askSerial = 0
    var expandedGroups: Set<String> = [""]
    var filter = ""
    var question = ""
    var selection = 0
    private(set) var sidebarGroups: [(DocsGroup, [DocsPage])] = []
    private(set) var appliedFilter = ""
    var filterDelay: Duration = .milliseconds(200)
    var matchPages: @Sendable ([DocsGroup], String) -> [(DocsGroup, [DocsPage])] = {
        groups, filter in
        DocsNavigation.visibleGroups(groups, filter: filter)
    }

    private var filterGeneration = 0
    private var filterTask: Task<Void, Never>?
    private var suppliedLibrary = false
    private var loadTask: Task<Void, Never>?
    private var askTask: Task<DocsAnswer, Never>?
    private var stopped = false
    private let defaults: UserDefaults

    init(
        library: DocsLibrary? = nil,
        matchPages: (@Sendable ([DocsGroup], String) -> [(DocsGroup, [DocsPage])])? = nil,
        filterDelay: Duration = .milliseconds(200),
        defaults: UserDefaults = SharedDefaults.store
    ) {
        self.defaults = defaults
        if let library {
            self.library = library
            suppliedLibrary = true
        } else if let ready = DocsLibrary.cached() {
            self.library = ready
            suppliedLibrary = true
        }
        self.filterDelay = filterDelay
        if let matchPages { self.matchPages = matchPages }
        if let groups = self.library?.groups { sidebarGroups = Self.listing(groups) }
    }

    var page: DocsPage? { library?.page(location.path) }

    func load() async {
        guard !stopped, !Task.isCancelled else { return }
        if suppliedLibrary { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await loadFresh() }
        loadTask = task
        await task.value
    }

    private func loadFresh() async {
        if let ready = DocsLibrary.cached() {
            adopt(ready)
            suppliedLibrary = true
            return
        }
        if library == nil {
            let index = await Task.detached(priority: .userInitiated) {
                DocsLibrary.openingPage()
            }.value
            guard !stopped, !Task.isCancelled else { return }
            if let index { adopt(DocsLibrary(pages: [index])) }
        }
        let loaded = await Task.detached(priority: .userInitiated) { DocsLibrary.bundled() }.value
        guard let loaded, !stopped, !Task.isCancelled else { return }
        adopt(loaded)
        suppliedLibrary = true
    }

    private func adopt(_ next: DocsLibrary) {
        library = next
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            appliedFilter = ""
            sidebarGroups = Self.listing(next.groups)
        } else {
            noteFilter(filter)
        }
    }

    func noteFilter(_ text: String) {
        guard !stopped else { return }
        filter = String(text.prefix(256))
        filterGeneration &+= 1
        let generation = filterGeneration
        filterTask?.cancel()
        filterTask = nil
        let groups = library?.groups ?? []
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            appliedFilter = ""
            sidebarGroups = Self.listing(groups)
            return
        }
        let delay = filterDelay
        let matchPages = matchPages
        let query = String(text.prefix(256))
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.filterGeneration == generation else { return }
            let matched = await Task.detached { matchPages(groups, query) }.value
            guard !Task.isCancelled, self.filterGeneration == generation else { return }
            self.appliedFilter = query
            self.sidebarGroups = matched
        }
    }

    func settleFilter() async {
        await filterTask?.value
    }

    private static func listing(_ groups: [DocsGroup]) -> [(DocsGroup, [DocsPage])] {
        var rows: [(DocsGroup, [DocsPage])] = []
        rows.reserveCapacity(groups.count)
        for group in groups { rows.append((group, group.pages)) }
        return rows
    }

    func open(_ target: DocsLocation, reveal: Bool = true) {
        guard !stopped, library?.page(target.path) != nil else { return }
        show(target, reveal: reveal)
    }

    func follow(_ link: DocsLink) {
        switch link {
        case .page(let path, let anchor): open(DocsLocation(path: path, anchor: anchor))
        case .external(let url): NSWorkspace.shared.open(url)
        }
    }

    func toggle(_ group: String) {
        if expandedGroups.contains(group) {
            expandedGroups.remove(group)
        } else {
            expandedGroups.insert(group)
        }
    }

    func endFlash(_ anchor: String?) {
        if flashAnchor == anchor { flashAnchor = nil }
    }

    func submit() async {
        await submit(decider: DocsPeerDecider.configured())
    }

    func submit(decider: JevDeciding?) async {
        let request = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stopped, !request.isEmpty, request.utf8.count <= 4096 else { return }
        if answer?.request == request, answer?.picks.isEmpty == false {
            if resultsVisible {
                openSelection()
            } else {
                resultsVisible = true
            }
            return
        }
        await ask(request, decider: decider)
    }

    func ask(_ request: String, decider: JevDeciding?) async {
        guard let library, !stopped, request.utf8.count <= 4096 else { return }
        askTask?.cancel()
        askSerial += 1
        let serial = askSerial
        asking = true
        let task = Task {
            await DocsAsk.answer(
                request, in: library, decider: decider, defaults: defaults)
        }
        askTask = task
        let answered = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !stopped, !Task.isCancelled, !task.isCancelled, serial == askSerial else { return }
        askTask = nil
        answer = answered
        selection = 0
        asking = false
        resultsVisible = true
    }

    func questionChanged() {
        if !answerIsCurrent { resultsVisible = false }
    }

    private var answerIsCurrent: Bool {
        answer?.request == question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func moveSelection(_ offset: Int) {
        guard answerIsCurrent, let count = answer?.picks.count, count > 0 else { return }
        resultsVisible = true
        selection = min(max(selection + offset, 0), count - 1)
    }

    func openSelection() {
        guard let picks = answer?.picks, picks.indices.contains(selection) else { return }
        open(picks[selection].command.location)
        resultsVisible = false
    }

    func openPick(_ pick: DocsPick) {
        if let index = answer?.picks.firstIndex(of: pick) { selection = index }
        openSelection()
    }

    func hideResults() {
        resultsVisible = false
    }

    func clearQuestion() -> Bool {
        guard !question.isEmpty || answer != nil else { return false }
        askSerial += 1
        askTask?.cancel()
        askTask = nil
        question = ""
        answer = nil
        asking = false
        resultsVisible = false
        return true
    }

    func shutdown() {
        stopped = true
        askSerial += 1
        filterGeneration &+= 1
        askTask?.cancel()
        filterTask?.cancel()
        loadTask?.cancel()
        askTask = nil
        filterTask = nil
        loadTask = nil
        asking = false
        resultsVisible = false
        answer = nil
        sidebarGroups = []
        library = nil
    }

    private func show(_ target: DocsLocation, reveal: Bool = true) {
        location = target
        if reveal { revealSerial += 1 }
        if let group = library?.page(target.path)?.group { expandedGroups.insert(group) }
        flashAnchor = target.anchor
        scroll = DocsScrollRequest(anchor: target.anchor, serial: scroll.serial + 1)
    }
}
