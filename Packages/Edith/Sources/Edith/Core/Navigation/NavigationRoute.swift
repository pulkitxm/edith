import AppKit
import Observation

struct NavigationRoute: Equatable, Sendable {
    var segments: [String]

    var description: String {
        segments.map(Self.encode).joined(separator: "/")
    }

    init(segments: [String]) {
        self.segments = segments.filter { !$0.isEmpty }
    }

    init?(_ description: String) {
        let raw = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        segments = parts.map { Self.decode($0) }
    }

    static func encode(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    static func decode(_ segment: String) -> String {
        segment.removingPercentEncoding ?? segment
    }
}

struct NavigationHistory: Equatable {
    private(set) var entries: [String] = []
    private(set) var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }
    var current: String? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    mutating func record(_ location: String) {
        guard !location.isEmpty else { return }
        if current == location { return }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(location)
        index = entries.count - 1
    }

    mutating func goBack() -> String? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func goForward() -> String? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }

    mutating func replaceCurrent(_ location: String) {
        guard !location.isEmpty else { return }
        guard entries.indices.contains(index) else {
            record(location)
            return
        }
        entries[index] = location
        collapseAdjacentDuplicates()
    }

    mutating func coalesceExtension(_ location: String) {
        guard let current else {
            record(location)
            return
        }
        guard location != current else { return }
        if location.hasPrefix(current + "/") || Self.extends(current, to: location) {
            replaceCurrent(location)
        } else {
            record(location)
        }
    }

    private static func extends(_ current: String, to location: String) -> Bool {
        let existing = current.split(separator: "/").map(String.init)
        let next = location.split(separator: "/").map(String.init)
        guard next.count > existing.count else { return false }
        var index = 0
        for part in next where index < existing.count && existing[index] == part {
            index += 1
        }
        return index == existing.count
    }

    private mutating func collapseAdjacentDuplicates() {
        var collapsed: [String] = []
        var newIndex = index
        for (offset, entry) in entries.enumerated() {
            if collapsed.last == entry {
                if offset <= index { newIndex -= 1 }
                continue
            }
            collapsed.append(entry)
        }
        entries = collapsed
        if entries.isEmpty {
            index = -1
        } else {
            index = min(max(newIndex, 0), entries.count - 1)
        }
    }
}

@MainActor
@Observable
final class WindowRouter {
    enum Role {
        case main
        case auxiliary
    }

    struct Slot {
        let depth: Int
        let name: String
        var order: Int
        var value: String
        var accept: (String) -> Bool
        var apply: (String) -> Void
    }

    private(set) var history = NavigationHistory()
    private(set) var restoring = false
    private(set) var lastRestoreRejected = false
    @ObservationIgnored private var slots: [Slot] = []
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var nextOrder = 0
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var passDepth = 0
    @ObservationIgnored private var passAgain = false
    @ObservationIgnored private var settleGeneration = 0
    @ObservationIgnored private weak var attachedWindow: NSWindow?
    @ObservationIgnored private static var registry: [ObjectIdentifier: WindowRouter] = [:]
    @ObservationIgnored private static weak var mainRouter: WindowRouter?

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    private var slotLocation: String {
        let values = slots.sorted(by: Self.ordered).map(\.value).filter { !$0.isEmpty }
        return NavigationRoute(segments: values).description
    }

    var location: String {
        let landed = slotLocation
        guard !lastRestoreRejected, let current = history.current else { return landed }
        if current == landed || current.hasPrefix(landed + "/") { return current }
        return landed
    }

    static var commandTarget: WindowRouter? {
        forKeyWindow() ?? mainRouter
    }

    static func router(for window: NSWindow) -> WindowRouter? {
        registry[ObjectIdentifier(window)]
    }

    static func forKeyWindow() -> WindowRouter? {
        guard let window = NSApp.keyWindow else { return nil }
        return router(for: window)
    }

    func attach(_ window: NSWindow, role: Role) {
        if let attachedWindow, attachedWindow !== window {
            let previous = ObjectIdentifier(attachedWindow)
            if Self.registry[previous] === self { Self.registry.removeValue(forKey: previous) }
        }
        attachedWindow = window
        Self.registry[ObjectIdentifier(window)] = self
        if role == .main { Self.mainRouter = self }
    }

    func detach() {
        if let attachedWindow {
            let key = ObjectIdentifier(attachedWindow)
            if Self.registry[key] === self { Self.registry.removeValue(forKey: key) }
        }
        if Self.mainRouter === self { Self.mainRouter = nil }
        attachedWindow = nil
    }

    func sync(
        depth: Int, name: String, value: String, accept: @escaping (String) -> Bool,
        apply: @escaping (String) -> Void
    ) {
        guard let index = slots.firstIndex(where: { $0.depth == depth && $0.name == name }) else {
            register(depth: depth, name: name, value: value, accept: accept, apply: apply)
            return
        }
        let previous = slots[index].value
        slots[index].accept = accept
        slots[index].apply = apply
        guard previous != value else { return }
        slots[index].value = value
        if restoring || applying || passDepth > 0 { return }
        slots.removeAll { $0.depth > depth }
        history.record(slotLocation)
    }

    func register(
        depth: Int, name: String, value: String, accept: @escaping (String) -> Bool,
        apply: @escaping (String) -> Void
    ) {
        if let index = slots.firstIndex(where: { $0.depth == depth && $0.name == name }) {
            slots[index].value = value
            slots[index].accept = accept
            slots[index].apply = apply
        } else {
            nextOrder += 1
            slots.append(
                Slot(
                    depth: depth, name: name, order: nextOrder, value: value, accept: accept,
                    apply: apply))
        }
        if restoring {
            applyPending()
            return
        }
        let landed = slotLocation
        if history.current == nil {
            history.record(landed)
        } else if landed != history.current {
            history.coalesceExtension(landed)
        }
    }

    func userChanged(
        depth: Int, name: String, value: String, accept: @escaping (String) -> Bool,
        apply: @escaping (String) -> Void
    ) {
        guard let index = slots.firstIndex(where: { $0.depth == depth && $0.name == name }) else {
            register(depth: depth, name: name, value: value, accept: accept, apply: apply)
            return
        }
        slots[index].accept = accept
        slots[index].apply = apply
        slots[index].value = value
        if restoring || applying || passDepth > 0 { return }
        slots.removeAll { $0.depth > depth }
        history.record(slotLocation)
    }

    func unregister(depth: Int, name: String) {
        slots.removeAll { $0.depth == depth && $0.name == name }
    }

    func goBack() {
        guard let raw = history.goBack(), let route = NavigationRoute(raw) else { return }
        beginRestore(route)
    }

    func goForward() {
        guard let raw = history.goForward(), let route = NavigationRoute(raw) else { return }
        beginRestore(route)
    }

    func navigate(to raw: String) {
        guard let route = NavigationRoute(raw) else { return }
        if history.current != route.description { history.record(route.description) }
        beginRestore(route)
    }

    private func beginRestore(_ route: NavigationRoute) {
        restoring = true
        lastRestoreRejected = false
        pending = route.segments
        settleGeneration += 1
        applyPending()
    }

    private func applyPending() {
        if passDepth > 0 {
            passAgain = true
            return
        }
        passDepth = 1
        defer {
            passDepth = 0
            if passAgain {
                passAgain = false
                applyPending()
            }
        }
        let ordered = slots.sorted(by: Self.ordered)
        let snapshot = ordered.map { (depth: $0.depth, name: $0.name, value: $0.value) }
        var pointer = 0
        var rejected = false
        applying = true
        for slot in ordered {
            if pointer >= pending.count {
                if !slot.value.isEmpty { write(slot, "") }
                continue
            }
            let component = pending[pointer]
            if slot.value == component {
                pointer += 1
                continue
            }
            if slot.accept(component) {
                write(slot, component)
                pointer += 1
                continue
            }
            if slot.value.isEmpty {
                let laterAccepts = ordered.contains { candidate in
                    let after =
                        candidate.depth > slot.depth
                        || (candidate.depth == slot.depth && candidate.order > slot.order)
                    return after && (candidate.value == component || candidate.accept(component))
                }
                if laterAccepts { continue }
                rejected = true
                break
            }
            rejected = true
            break
        }
        if rejected {
            for item in snapshot {
                guard
                    let index = slots.firstIndex(where: {
                        $0.depth == item.depth && $0.name == item.name
                    }),
                    slots[index].value != item.value
                else { continue }
                write(slots[index], item.value)
            }
            lastRestoreRejected = true
        }
        applying = false
        if passAgain { return }
        let waiting = !rejected && pointer < pending.count
        if waiting {
            scheduleSettle()
        } else {
            finishRestore()
        }
    }

    private func write(_ slot: Slot, _ value: String) {
        guard
            let index = slots.firstIndex(where: { $0.depth == slot.depth && $0.name == slot.name })
        else { return }
        slots[index].value = value
        slots[index].apply(value)
    }

    private func clearDeeper(than depth: Int) {
        let deeper = slots.filter { $0.depth > depth }
        for slot in deeper where !slot.value.isEmpty {
            write(slot, "")
        }
        slots.removeAll { $0.depth > depth }
    }

    private func finishRestore() {
        restoring = false
        pending = []
        settleGeneration += 1
        let landed = slotLocation
        guard lastRestoreRejected else { return }
        if landed.isEmpty {
            history.replaceCurrent(history.current ?? "")
        } else if landed != history.current {
            history.replaceCurrent(landed)
        }
    }

    private func scheduleSettle() {
        settleGeneration += 1
        let generation = settleGeneration
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.restoring, self.settleGeneration == generation else { return }
                self.finishRestore()
            }
        }
    }

    private static func ordered(_ lhs: Slot, _ rhs: Slot) -> Bool {
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        return lhs.order < rhs.order
    }
}

@MainActor
enum NavigationCommands {
    static func perform(action: String, route: String?) -> [String: Any] {
        guard let router = WindowRouter.commandTarget else {
            return ["ok": false, "error": "the main window has not registered a route"]
        }
        switch action {
        case "route":
            break
        case "navigate":
            let raw = route ?? ""
            guard NavigationRoute(raw) != nil else {
                return ["ok": false, "error": "route is empty or malformed"]
            }
            router.navigate(to: raw)
            if router.lastRestoreRejected {
                return [
                    "ok": false,
                    "error": "route was rejected",
                    "route": router.location,
                    "canGoBack": router.canGoBack,
                    "canGoForward": router.canGoForward,
                ]
            }
        case "back":
            guard router.canGoBack else {
                return ["ok": false, "error": "nothing to go back to"]
            }
            router.goBack()
        case "forward":
            guard router.canGoForward else {
                return ["ok": false, "error": "nothing to go forward to"]
            }
            router.goForward()
        default:
            return ["ok": false, "error": "unknown navigation action"]
        }
        return [
            "ok": true,
            "route": router.location,
            "canGoBack": router.canGoBack,
            "canGoForward": router.canGoForward,
        ]
    }
}
