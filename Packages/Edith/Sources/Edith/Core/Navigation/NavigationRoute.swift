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
        let owner: UUID?
        var order: Int
        var value: String
        var ready: Bool
        var scope: [String]
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
    @ObservationIgnored private var settlePausedForReadiness = false
    @ObservationIgnored private var staleOrders: Set<Int> = []
    @ObservationIgnored private var restoreSource: NavigationHistory?
    @ObservationIgnored private let restoreTimeout: TimeInterval
    @ObservationIgnored private weak var attachedWindow: NSWindow?
    @ObservationIgnored private static var registry: [ObjectIdentifier: WindowRouter] = [:]
    @ObservationIgnored private static weak var mainRouter: WindowRouter?

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    init(restoreTimeout: TimeInterval = 0.75) {
        self.restoreTimeout = restoreTimeout
    }

    private var slotLocation: String {
        var values: [String] = []
        for slot in slots where !staleOrders.contains(slot.order) && !slot.value.isEmpty {
            values.append(slot.value)
        }
        return NavigationRoute(segments: values).description
    }

    var location: String {
        if restoring, let current = history.current { return current }
        return slotLocation
    }

    static var commandTarget: WindowRouter? {
        forKeyWindow() ?? mainRouter
    }

    static func router(for window: NSWindow?) -> WindowRouter? {
        guard let window else { return nil }
        return registry[ObjectIdentifier(window)]
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
        depth: Int, name: String, value: String, owner: UUID? = nil, ready: Bool = true,
        scope: [String] = [],
        accept: @escaping (String) -> Bool,
        apply: @escaping (String) -> Void
    ) {
        guard
            let index = slots.firstIndex(where: {
                $0.depth == depth && $0.name == name && $0.owner == owner
            })
        else {
            register(
                depth: depth, name: name, value: value, owner: owner, ready: ready, scope: scope,
                accept: accept,
                apply: apply)
            return
        }
        let rejoining = staleOrders.contains(slots[index].order)
        if rejoining {
            guard slots[index].scope != scope else { return }
            staleOrders.remove(slots[index].order)
            slots[index].value = value
        }
        slots[index].scope = scope
        let previous = slots[index].value
        slots[index].accept = accept
        slots[index].apply = apply
        slots[index].ready = ready
        if restoring {
            if !applying { applyPending() }
            return
        }
        guard previous != value || rejoining else { return }
        slots[index].value = value
        if restoring || applying || passDepth > 0 { return }
        invalidateDescendants(depth: depth, value: value)
        if rejoining {
            history.coalesceExtension(slotLocation)
        } else {
            history.record(slotLocation)
        }
    }

    func register(
        depth: Int, name: String, value: String, owner: UUID? = nil, ready: Bool = true,
        scope: [String] = [],
        accept: @escaping (String) -> Bool,
        apply: @escaping (String) -> Void
    ) {
        if let index = slots.firstIndex(where: {
            $0.depth == depth && $0.name == name && $0.owner == owner
        }) {
            staleOrders.remove(slots[index].order)
            slots[index].value = value
            slots[index].ready = ready
            slots[index].scope = scope
            slots[index].accept = accept
            slots[index].apply = apply
        } else {
            nextOrder += 1
            let slot = Slot(
                depth: depth, name: name, owner: owner, order: nextOrder, value: value,
                ready: ready, scope: scope, accept: accept,
                apply: apply)
            let insertion = slots.firstIndex { Self.ordered(slot, $0) } ?? slots.endIndex
            slots.insert(slot, at: insertion)
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
        invalidateDescendants(depth: depth, value: value)
        history.record(slotLocation)
    }

    func unregister(depth: Int, name: String, owner: UUID? = nil) {
        guard
            let slot = slots.first(where: {
                $0.depth == depth && $0.name == name && $0.owner == owner
            })
        else { return }
        slots.removeAll { $0.order == slot.order }
        let wasStale = staleOrders.remove(slot.order) != nil
        if wasStale { return }
        if restoring { applyPending() } else { history.replaceCurrent(slotLocation) }
    }

    func goBack() {
        let source = history
        guard let raw = history.goBack(), let route = NavigationRoute(raw) else { return }
        beginRestore(route, source: source)
    }

    func goForward() {
        let source = history
        guard let raw = history.goForward(), let route = NavigationRoute(raw) else { return }
        beginRestore(route, source: source)
    }

    func navigate(to raw: String) {
        guard let route = NavigationRoute(raw) else { return }
        if history.current != route.description { history.record(route.description) }
        beginRestore(route)
    }

    private func beginRestore(_ route: NavigationRoute, source: NavigationHistory? = nil) {
        restoring = true
        lastRestoreRejected = false
        pending = route.segments
        restoreSource = source
        settleGeneration += 1
        settlePausedForReadiness = false
        scheduleSettle()
        applyPending()
    }

    private func applyPending() {
        guard restoring else { return }
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
        var ordered: [Slot] = []
        for slot in slots where !staleOrders.contains(slot.order) { ordered.append(slot) }
        let snapshot = ordered
        var pointer = 0
        var rejected = false
        var waitingForReadiness = false
        applying = true
        for slot in ordered {
            if staleOrders.contains(slot.order) { continue }
            if pointer >= pending.count && slot.value.isEmpty { continue }
            if !slot.ready {
                waitingForReadiness = true
                break
            }
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
                    return after && !staleOrders.contains(candidate.order)
                        && candidate.ready
                        && (candidate.value == component || candidate.accept(component))
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
                        $0.order == item.order
                    }),
                    slots[index].value != item.value
                else { continue }
                write(slots[index], item.value)
            }
            lastRestoreRejected = true
        }
        applying = false
        if rejected, let source = restoreSource, let raw = source.current,
            let route = NavigationRoute(raw)
        {
            history = source
            beginRestore(route)
            lastRestoreRejected = true
            return
        }
        if passAgain { return }
        let waiting = !rejected && (pointer < pending.count || waitingForReadiness)
        if waiting && !waitingForReadiness && settlePausedForReadiness {
            settlePausedForReadiness = false
            scheduleSettle()
        }
        if !waiting {
            finishRestore()
        }
    }

    private func write(_ slot: Slot, _ value: String) {
        guard
            let index = slots.firstIndex(where: { $0.order == slot.order })
        else { return }
        if slots[index].value != value {
            invalidateDescendants(depth: slot.depth, value: value)
        }
        slots[index].value = value
        slots[index].apply(value)
    }

    private func finishRestore() {
        restoring = false
        pending = []
        restoreSource = nil
        settlePausedForReadiness = false
        settleGeneration += 1
        history.replaceCurrent(slotLocation)
    }

    private func invalidateDescendants(depth: Int, value: String) {
        for slot in slots where slot.depth > depth {
            if !slot.scope.indices.contains(depth) || slot.scope[depth] != value {
                staleOrders.insert(slot.order)
            }
        }
    }

    private func scheduleSettle() {
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreTimeout) { [weak self] in
            guard let self, self.restoring, self.settleGeneration == generation else { return }
            if self.slots.contains(where: { !self.staleOrders.contains($0.order) && !$0.ready }) {
                self.settlePausedForReadiness = true
                return
            }
            self.finishRestore()
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
