import AppKit
import EdithDocs
import EdithKit
import Observation

struct DocsScrollRequest: Equatable {
    let anchor: String?
    let serial: Int
}

@MainActor @Observable
final class DocsBrowser {
    static let shared = DocsBrowser()

    private(set) var library: DocsLibrary?
    private(set) var location = DocsLocation(path: DocsLibrary.indexPath)
    private(set) var scroll = DocsScrollRequest(anchor: nil, serial: 0)
    private(set) var revealSerial = 0
    private(set) var flashAnchor: String?
    private(set) var answer: DocsAnswer?
    private(set) var asking = false
    private(set) var resultsVisible = false
    private var backStack: [DocsLocation] = []
    private var forwardStack: [DocsLocation] = []
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

    init(
        library: DocsLibrary? = nil,
        matchPages: (@Sendable ([DocsGroup], String) -> [(DocsGroup, [DocsPage])])? = nil,
        filterDelay: Duration = .milliseconds(200)
    ) {
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
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func load() async {
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
            if let index { adopt(DocsLibrary(pages: [index])) }
        }
        let loaded = await Task.detached(priority: .userInitiated) { DocsLibrary.bundled() }.value
        guard let loaded else { return }
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
        let query = text
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
        guard library?.page(target.path) != nil else { return }
        if target != location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        show(target, reveal: reveal)
    }

    func follow(_ link: DocsLink) {
        switch link {
        case .page(let path, let anchor): open(DocsLocation(path: path, anchor: anchor))
        case .external(let url): NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        forwardStack.append(location)
        show(previous)
        return true
    }

    @discardableResult
    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(location)
        show(next)
        return true
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

    func submit(decider: JevDeciding? = AgentJevDecider.configured()) async {
        let request = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
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
        guard let library else { return }
        askSerial += 1
        let serial = askSerial
        asking = true
        let answered = await DocsAsk.answer(request, in: library, decider: decider)
        guard serial == askSerial else { return }
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
        question = ""
        answer = nil
        asking = false
        resultsVisible = false
        return true
    }

    private func show(_ target: DocsLocation, reveal: Bool = true) {
        location = target
        if reveal { revealSerial += 1 }
        if let group = library?.page(target.path)?.group { expandedGroups.insert(group) }
        flashAnchor = target.anchor
        scroll = DocsScrollRequest(anchor: target.anchor, serial: scroll.serial + 1)
    }
}
