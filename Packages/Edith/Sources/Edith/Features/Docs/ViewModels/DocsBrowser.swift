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

    init(library: DocsLibrary? = nil) {
        self.library = library
    }

    var page: DocsPage? { library?.page(location.path) }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func load() async {
        guard library == nil else { return }
        let loaded = await Task.detached(priority: .userInitiated) { DocsLibrary.bundled() }.value
        guard library == nil else { return }
        library = loaded
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
