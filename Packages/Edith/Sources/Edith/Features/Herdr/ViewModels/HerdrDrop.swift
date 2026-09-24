import AppKit
import EdithKit
import Observation
import SwiftUI

enum HerdrDragItem: Equatable {
    case agent(HerdrAgent)
    case tab(String)
}

enum HerdrDropTarget: Equatable {
    case edge(String, InsertSide)
    case outerEdge(InsertSide)
    case center(String)
    case slot(HerdrArrangement, Int)
    case tabBar(Int)
    case intoTab(String)
    case newTab
    case window

    var placesInCanvas: Bool {
        switch self {
        case .edge, .outerEdge, .center, .slot: true
        case .tabBar, .intoTab, .newTab, .window: false
        }
    }
}

struct HerdrTabChip: Equatable {
    let id: String
    let frame: CGRect
}

struct HerdrDropGeometry: Equatable {
    var page: CGRect = .zero
    var tabBar: CGRect = .zero
    var canvas: CGRect = .zero
    var chips: [HerdrTabChip] = []

    static let pageKey = "page"
    static let tabBarKey = "tabBar"
    static let canvasKey = "canvas"
    static let chipPrefix = "tab:"

    static func make(frames: [String: CGRect], order: [String]) -> HerdrDropGeometry {
        HerdrDropGeometry(
            page: frames[pageKey] ?? .zero,
            tabBar: frames[tabBarKey] ?? .zero,
            canvas: frames[canvasKey] ?? .zero,
            chips: order.compactMap { id in
                frames[chipPrefix + id].map { HerdrTabChip(id: id, frame: $0) }
            })
    }
}

struct HerdrSnapThumbnail: Equatable {
    let arrangement: HerdrArrangement
    let frame: CGRect
    let slots: [CGRect]
}

struct HerdrSnapBar: Equatable {
    let count: Int
    let frame: CGRect
    let expanded: Bool
    let thumbnails: [HerdrSnapThumbnail]

    static let trigger: CGFloat = 96

    static func make(
        count: Int, canvas: CGRect, pointer: CGPoint, unit: CGFloat, wasExpanded: Bool
    ) -> HerdrSnapBar? {
        let options = HerdrArrangement.options(for: count)
        guard !options.isEmpty, canvas.width > 0 else { return nil }
        let size = CGSize(width: 64 * unit, height: 42 * unit)
        let spacing = 8 * unit
        let padding = 10 * unit
        let label = 14 * unit
        let usable = max(size.width, canvas.width - 48 * unit - padding * 2)
        let perRow = max(1, min(options.count, Int((usable + spacing) / (size.width + spacing))))
        let rows = (options.count + perRow - 1) / perRow
        let width = CGFloat(perRow) * size.width + CGFloat(perRow - 1) * spacing + padding * 2
        let height =
            CGFloat(rows) * (size.height + label) + CGFloat(rows - 1) * spacing + padding * 2
        let full = CGRect(
            x: canvas.midX - width / 2, y: canvas.minY + 10 * unit, width: width, height: height)
        let reach = full.insetBy(dx: -28 * unit, dy: -28 * unit)
        let expanded =
            pointer.y <= canvas.minY + trigger * unit && abs(pointer.x - canvas.midX) <= width
            || (wasExpanded && reach.contains(pointer))
        guard expanded else {
            let pill = CGRect(
                x: canvas.midX - 70 * unit, y: canvas.minY + 10 * unit, width: 140 * unit,
                height: 26 * unit)
            return HerdrSnapBar(count: count, frame: pill, expanded: false, thumbnails: [])
        }
        let thumbnails = options.enumerated().map { index, arrangement in
            let row = index / perRow
            let column = index % perRow
            let frame = CGRect(
                x: full.minX + padding + CGFloat(column) * (size.width + spacing),
                y: full.minY + padding + CGFloat(row) * (size.height + label + spacing),
                width: size.width, height: size.height)
            return HerdrSnapThumbnail(
                arrangement: arrangement, frame: frame,
                slots: arrangement.slotFrames(
                    count: count, in: frame.insetBy(dx: 4 * unit, dy: 4 * unit), gap: 2 * unit))
        }
        return HerdrSnapBar(count: count, frame: full, expanded: true, thumbnails: thumbnails)
    }

    func slot(at point: CGPoint) -> (HerdrArrangement, Int)? {
        for thumbnail in thumbnails where thumbnail.frame.insetBy(dx: -2, dy: -2).contains(point) {
            if let index = thumbnail.slots.firstIndex(where: {
                $0.insetBy(dx: -1.5, dy: -1.5).contains(point)
            }) {
                return (thumbnail.arrangement, index)
            }
            let nearest = thumbnail.slots.indices.min { first, second in
                Self.distance(point, thumbnail.slots[first])
                    < Self.distance(point, thumbnail.slots[second])
            }
            return nearest.map { (thumbnail.arrangement, $0) }
        }
        return nil
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        hypot(point.x - rect.midX, point.y - rect.midY)
    }
}

enum HerdrDropResolver {
    static let edgeBand: CGFloat = 0.28
    static let stickyBand: CGFloat = 0.36
    static let outerBand: CGFloat = 18

    static func target(
        at point: CGPoint, geometry: HerdrDropGeometry, tab: HerdrTab?, boardID: String,
        snapBar: HerdrSnapBar?, previous: HerdrDropTarget?, gap: CGFloat
    ) -> HerdrDropTarget? {
        if !geometry.page.isEmpty, !geometry.page.contains(point) { return .window }
        if geometry.tabBar.contains(point) {
            return tabBarTarget(at: point, chips: geometry.chips, boardID: boardID)
        }
        guard geometry.canvas.contains(point) else { return nil }
        guard let tab else { return .newTab }
        if let snapBar, snapBar.expanded, snapBar.frame.contains(point) {
            return snapBar.slot(at: point).map { .slot($0.0, $0.1) }
        }
        let canvas = geometry.canvas
        if tab.isSplit, tab.zoomed == nil, let side = outerSide(point, canvas) {
            return .outerEdge(side)
        }
        let frames: [String: CGRect] =
            tab.zoomed.map { [$0: tab.layout.content(in: canvas, gap: gap)] }
            ?? tab.layout.paneFrames(in: canvas, gap: gap)
        guard let (id, frame) = frames.first(where: { $0.value.contains(point) }) else {
            return previous?.placesInCanvas == true ? previous : nil
        }
        return paneTarget(id: id, frame: frame, point: point, previous: previous)
    }

    static func tabBarTarget(at point: CGPoint, chips: [HerdrTabChip], boardID: String)
        -> HerdrDropTarget
    {
        let tabs = chips.filter { $0.id != boardID }
        if let board = chips.first(where: { $0.id == boardID }), board.frame.maxX >= point.x {
            return .tabBar(0)
        }
        for (index, chip) in tabs.enumerated() {
            guard point.x <= chip.frame.maxX else { continue }
            guard point.x >= chip.frame.minX else { return .tabBar(index) }
            let relative = (point.x - chip.frame.minX) / max(1, chip.frame.width)
            if relative < 0.25 { return .tabBar(index) }
            if relative > 0.75 { return .tabBar(index + 1) }
            return .intoTab(chip.id)
        }
        return .tabBar(tabs.count)
    }

    static func outerSide(_ point: CGPoint, _ canvas: CGRect) -> InsertSide? {
        let distances: [(InsertSide, CGFloat)] = [
            (.left, point.x - canvas.minX), (.right, canvas.maxX - point.x),
            (.top, point.y - canvas.minY), (.bottom, canvas.maxY - point.y),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < outerBand else {
            return nil
        }
        return nearest.0
    }

    static func paneTarget(
        id: String, frame: CGRect, point: CGPoint, previous: HerdrDropTarget?
    ) -> HerdrDropTarget {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let distances: [(InsertSide, CGFloat)] = [
            (.left, (point.x - frame.minX) / width), (.right, (frame.maxX - point.x) / width),
            (.top, (point.y - frame.minY) / height), (.bottom, (frame.maxY - point.y) / height),
        ]
        let nearest = distances.min { $0.1 < $1.1 } ?? (.left, 1)
        if case let .edge(previousID, side) = previous, previousID == id,
            let distance = distances.first(where: { $0.0 == side })?.1, distance < stickyBand
        {
            return .edge(id, side)
        }
        if case let .center(previousID) = previous, previousID == id,
            nearest.1 >= edgeBand - 0.06
        {
            return .center(id)
        }
        return nearest.1 < edgeBand ? .edge(id, nearest.0) : .center(id)
    }
}

@MainActor
@Observable
final class HerdrDragCoordinator {
    static let space = "herdr.page"
    static let springDelay: Duration = .milliseconds(550)
    static let deadZone: CGFloat = 18

    private(set) var item: HerdrDragItem?
    private(set) var location: CGPoint = .zero
    private(set) var target: HerdrDropTarget?
    private(set) var snapBar: HerdrSnapBar?
    var frames: [String: CGRect] = [:]

    var geometry: HerdrDropGeometry {
        .make(frames: frames, order: store?.orderedTabIDs ?? [])
    }

    @ObservationIgnored weak var store: HerdrStore?
    @ObservationIgnored var gap: CGFloat = 6
    @ObservationIgnored var unit: CGFloat = 1
    @ObservationIgnored var animation: Animation?
    @ObservationIgnored var onTearOff: ((HerdrAgent) -> Void)?
    @ObservationIgnored private var springTask: Task<Void, Never>?
    @ObservationIgnored private var springTarget: String?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var origin: CGPoint?

    var active: Bool { item != nil }

    func update(_ item: HerdrDragItem, at point: CGPoint, from start: CGPoint? = nil) {
        if let start, start != origin {
            reset()
            origin = start
        }
        guard !cancelled else { return }
        if self.item != item { begin(item) }
        location = point
        resolve()
    }

    func finish(_ item: HerdrDragItem, at point: CGPoint, from start: CGPoint? = nil) {
        update(item, at: point, from: start)
        defer { reset() }
        guard !cancelled, self.item != nil, let target, let store else { return }
        if target == .window {
            if case let .agent(agent) = store.normalized(item) { onTearOff?(agent) }
            return
        }
        withAnimation(animation) { store.drop(item, on: target) }
    }

    func cancel() {
        guard item != nil else { return }
        cancelled = true
        item = nil
        target = nil
        snapBar = nil
        stopSpring()
        removeKeyMonitor()
    }

    private func begin(_ item: HerdrDragItem) {
        self.item = item
        target = nil
        snapBar = nil
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.active else { return event }
            self.cancel()
            return nil
        }
    }

    private func reset() {
        item = nil
        target = nil
        snapBar = nil
        cancelled = false
        origin = nil
        stopSpring()
        removeKeyMonitor()
    }

    private func resolve() {
        guard let store, let item else { return }
        if let origin, hypot(location.x - origin.x, location.y - origin.y) < Self.deadZone * unit {
            snapBar = nil
            target = nil
            stopSpring()
            return
        }
        let tab = store.currentTab
        if geometry.canvas.contains(location), let count = store.snapCount(for: item) {
            snapBar = HerdrSnapBar.make(
                count: count, canvas: geometry.canvas, pointer: location, unit: unit,
                wasExpanded: snapBar?.expanded == true)
        } else {
            snapBar = nil
        }
        let proposed = HerdrDropResolver.target(
            at: location, geometry: geometry, tab: tab, boardID: HerdrStore.boardID,
            snapBar: snapBar, previous: target, gap: gap)
        let accepted = proposed.flatMap { store.accepts(item, $0) ? $0 : nil }
        if accepted != target { target = accepted }
        spring(toward: accepted)
    }

    private func spring(toward target: HerdrDropTarget?) {
        guard case let .intoTab(id) = target, id != store?.selectedTab else {
            stopSpring()
            return
        }
        guard springTarget != id else { return }
        springTask?.cancel()
        springTarget = id
        springTask = Task { [weak self] in
            try? await Task.sleep(for: Self.springDelay)
            guard !Task.isCancelled, let self, self.target == .intoTab(id) else { return }
            withAnimation(self.animation) { self.store?.selectedTab = id }
            self.springTarget = nil
            self.resolve()
        }
    }

    private func stopSpring() {
        springTask?.cancel()
        springTask = nil
        springTarget = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct HerdrDropFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func herdrDropFrame(_ key: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HerdrDropFrames.self,
                    value: [key: proxy.frame(in: .named(HerdrDragCoordinator.space))])
            })
    }

    func herdrDraggable(_ item: HerdrDragItem, simultaneous: Bool = false) -> some View {
        modifier(HerdrDraggable(item: item, simultaneous: simultaneous))
    }
}

private struct HerdrDraggable: ViewModifier {
    let item: HerdrDragItem
    let simultaneous: Bool

    @Environment(HerdrDragCoordinator.self) private var drag: HerdrDragCoordinator?

    func body(content: Content) -> some View {
        if let drag {
            let gesture = DragGesture(
                minimumDistance: 6, coordinateSpace: .named(HerdrDragCoordinator.space)
            )
            .onChanged { drag.update(item, at: $0.location, from: $0.startLocation) }
            .onEnded { drag.finish(item, at: $0.location, from: $0.startLocation) }
            if simultaneous {
                content.simultaneousGesture(gesture)
            } else {
                content.gesture(gesture)
            }
        } else {
            content
        }
    }
}
