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

struct DocsLocalLibrary: Sendable {
    var cached: @Sendable () -> DocsLibrary?
    var opening: @Sendable () -> DocsPage?
    var bundled: @Sendable () -> DocsLibrary?

    static let live = Self(
        cached: { DocsLibrary.cached() }, opening: { DocsLibrary.openingPage() },
        bundled: { DocsLibrary.bundled() })
    static let none = Self(cached: { nil }, opening: { nil }, bundled: { nil })
}

struct DocsSession {
    var location = DocsLocation(path: DocsLibrary.indexPath)
    var expandedGroups: Set<String> = [""]
    var filter = ""
    var question = ""
    var answer: DocsPresentationAnswer?

    @MainActor static var last: DocsSession?
}

@MainActor @Observable
final class DocsBrowser {

    private(set) var library: DocsLibrary?
    private(set) var location = DocsLocation(path: DocsLibrary.indexPath)
    private(set) var scroll = DocsScrollRequest(anchor: nil, serial: 0)
    private(set) var revealSerial = 0
    private(set) var flashAnchor: String?
    private(set) var answer: DocsPresentationAnswer?
    private(set) var asking = false
    private(set) var resultsVisible = false
    private var askSerial = 0
    var expandedGroups: Set<String> = [""] { didSet { remember() } }
    var filter = ""
    var question = "" { didSet { remember() } }
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
    private var askTask: Task<DocsPresentationAnswer, Never>?
    private var stopped = false
    private var followWork: [UUID: Task<Void, Never>] = [:]
    private var cancelledWork: [UUID: Task<Void, Never>] = [:]
    private let defaults: UserDefaults
    private let remote: DocsUIBridge?
    private let local: DocsLocalLibrary

    init(
        library: DocsLibrary? = nil,
        matchPages: (@Sendable ([DocsGroup], String) -> [(DocsGroup, [DocsPage])])? = nil,
        filterDelay: Duration = .milliseconds(200),
        defaults: UserDefaults = SharedDefaults.store,
        remote: DocsUIBridge? = nil, local: DocsLocalLibrary = .live
    ) {
        self.defaults = defaults
        self.remote = remote
        self.local = local
        if let library {
            self.library = library
            suppliedLibrary = true
        } else if let ready = local.cached() {
            self.library = ready
            suppliedLibrary = true
        }
        self.filterDelay = filterDelay
        if let matchPages { self.matchPages = matchPages }
        if let groups = self.library?.groups { sidebarGroups = Self.listing(groups) }
        if remote != nil, let session = DocsSession.last {
            location = session.location
            expandedGroups = session.expandedGroups
            filter = session.filter
            question = session.question
            answer = session.answer
            scroll = DocsScrollRequest(anchor: session.location.anchor, serial: 1)
        }
        if !filter.trimmingCharacters(in: .whitespaces).isEmpty { startFilter() }
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
        if let ready = local.cached() {
            adopt(ready)
            suppliedLibrary = true
            return
        }
        if library == nil {
            let opening = local.opening
            let index = await Task.detached(priority: .userInitiated) { opening() }.value
            guard !stopped, !Task.isCancelled else { return }
            if let index { adopt(DocsLibrary(pages: [index])) }
        }
        let bundled = local.bundled
        let loaded = await Task.detached(priority: .userInitiated) { bundled() }.value
        guard !stopped, !Task.isCancelled else { return }
        if let loaded {
            adopt(loaded)
            suppliedLibrary = true
        } else if let remote {
            do {
                let next = try await remote.library()
                guard !stopped, !Task.isCancelled else { return }
                adopt(next)
                suppliedLibrary = true
            } catch {}
        }
    }

    private func remember() {
        guard remote != nil, !stopped else { return }
        DocsSession.last = DocsSession(
            location: location, expandedGroups: expandedGroups, filter: filter,
            question: question, answer: answer)
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
        remember()
        filterGeneration &+= 1
        filterTask?.cancel()
        if filter.trimmingCharacters(in: .whitespaces).isEmpty {
            appliedFilter = ""
            sidebarGroups = Self.listing(library?.groups ?? [])
        }
        startFilter()
    }

    private func startFilter() {
        guard !stopped, filterTask == nil, !filter.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return
        }
        let generation = filterGeneration
        let groups = library?.groups ?? []
        let delay = filterDelay
        let matchPages = matchPages
        let query = filter
        filterTask = Task { [self] in
            defer {
                filterTask = nil
                if generation != filterGeneration { startFilter() }
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !stopped, filterGeneration == generation else { return }
            let matched = await Task.detached { matchPages(groups, query) }.value
            guard !Task.isCancelled, !stopped, filterGeneration == generation else { return }
            appliedFilter = query
            sidebarGroups = matched
        }
    }

    func settleFilter() async {
        while let task = filterTask { await task.value }
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
        guard !stopped else { return }
        switch link {
        case .page(let path, let anchor): open(DocsLocation(path: path, anchor: anchor))
        case .external(let url):
            if let remote {
                let id = UUID()
                followWork[id] = Task { [self] in
                    defer { followWork[id] = nil }
                    guard !Task.isCancelled else { return }
                    try? await remote.follow(url)
                }
            } else {
                NSWorkspace.shared.open(url)
            }
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
        let previous = askTask
        previous?.cancel()
        askSerial += 1
        let serial = askSerial
        asking = true
        _ = await previous?.value
        guard !stopped, !Task.isCancelled, serial == askSerial else { return }
        let task = Task {
            if let remote = self.remote,
                let answered = try? await remote.answer(request, library: library)
            {
                return answered
            }
            return DocsPresentationAnswer(
                await DocsAsk.answer(
                    request, in: library, decider: self.remote == nil ? decider : nil,
                    defaults: defaults))
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
        remember()
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

    func openPick(_ pick: DocsPresentationPick) {
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
        question = ""
        answer = nil
        remember()
        asking = false
        resultsVisible = false
        return true
    }

    func cancelPendingWork() {
        guard !stopped else { return }
        stopped = true
        askSerial += 1
        filterGeneration &+= 1
        retire(askTask)
        retire(filterTask)
        retire(loadTask)
        askTask = nil
        filterTask = nil
        loadTask = nil
        for task in followWork.values { task.cancel() }
    }

    func shutdown() {
        cancelPendingWork()
        asking = false
        resultsVisible = false
        answer = nil
        sidebarGroups = []
        library = nil
    }

    private func retire<Value: Sendable>(_ task: Task<Value, Never>?) {
        guard let task else { return }
        task.cancel()
        let id = UUID()
        cancelledWork[id] = Task { [weak self] in
            _ = await task.value
            self?.cancelledWork[id] = nil
        }
    }

    func drain() async {
        cancelPendingWork()
        let pending = Array(cancelledWork.values) + Array(followWork.values)
        for task in pending { await task.value }
    }

    private func show(_ target: DocsLocation, reveal: Bool = true) {
        location = target
        remember()
        if reveal { revealSerial += 1 }
        if let group = library?.page(target.path)?.group { expandedGroups.insert(group) }
        flashAnchor = target.anchor
        scroll = DocsScrollRequest(anchor: target.anchor, serial: scroll.serial + 1)
    }
}
