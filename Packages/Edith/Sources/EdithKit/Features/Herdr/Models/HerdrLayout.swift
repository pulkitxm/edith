import CoreGraphics
import Foundation

public struct HerdrSplit: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var axis: SplitAxis
    public var children: [HerdrLayout]
    public var ratios: [Double]

    public init(
        id: UUID = UUID(), axis: SplitAxis, children: [HerdrLayout], ratios: [Double]? = nil
    ) {
        self.id = id
        self.axis = axis
        self.children = children
        self.ratios =
            ratios
            ?? Array(repeating: 1.0 / Double(max(1, children.count)), count: children.count)
    }
}

public indirect enum HerdrLayout: Codable, Hashable, Sendable {
    case pane(String)
    case split(HerdrSplit)
}

public struct HerdrLayoutDivider: Hashable, Sendable, Identifiable {
    public let splitID: UUID
    public let index: Int
    public let axis: SplitAxis
    public let rect: CGRect
    public let span: CGFloat

    public var id: String { "\(splitID.uuidString)-\(index)" }
}

extension HerdrLayout {
    public static let minimumShare = 0.08

    public static func stack(_ axis: SplitAxis, _ ids: [String], ratios: [Double]? = nil)
        -> HerdrLayout
    {
        group(axis, ids.map(HerdrLayout.pane), ratios: ratios)
    }

    public static func group(_ axis: SplitAxis, _ children: [HerdrLayout], ratios: [Double]? = nil)
        -> HerdrLayout
    {
        if children.count == 1 { return children[0] }
        return HerdrLayout.split(HerdrSplit(axis: axis, children: children, ratios: ratios))
            .normalized()
    }

    public var panes: [String] {
        switch self {
        case let .pane(id): [id]
        case let .split(split): split.children.flatMap(\.panes)
        }
    }

    public var paneCount: Int { panes.count }

    public func contains(_ id: String) -> Bool {
        switch self {
        case let .pane(pane): pane == id
        case let .split(split): split.children.contains { $0.contains(id) }
        }
    }

    public func inserting(_ node: HerdrLayout, near target: String, side: InsertSide)
        -> HerdrLayout
    {
        switch self {
        case let .pane(id):
            guard id == target else { return self }
            let children = side.isBefore ? [node, self] : [self, node]
            return .split(HerdrSplit(axis: side.axis, children: children, ratios: [0.5, 0.5]))
        case var .split(split):
            if split.axis == side.axis,
                let index = split.children.firstIndex(where: { $0 == .pane(target) })
            {
                let half = split.ratios[index] / 2
                split.ratios[index] = half
                let at = side.isBefore ? index : index + 1
                split.children.insert(node, at: at)
                split.ratios.insert(half, at: at)
                return HerdrLayout.split(split).normalized()
            }
            split.children = split.children.map {
                $0.contains(target) ? $0.inserting(node, near: target, side: side) : $0
            }
            return HerdrLayout.split(split).normalized()
        }
    }

    public func inserting(_ node: HerdrLayout, atEdge side: InsertSide) -> HerdrLayout {
        if case var .split(split) = self, split.axis == side.axis {
            let share = 1.0 / Double(split.children.count + 1)
            split.ratios = split.ratios.map { $0 * (1 - share) }
            let at = side.isBefore ? 0 : split.children.count
            split.children.insert(node, at: at)
            split.ratios.insert(share, at: at)
            return HerdrLayout.split(split).normalized()
        }
        let children = side.isBefore ? [node, self] : [self, node]
        return HerdrLayout.split(
            HerdrSplit(axis: side.axis, children: children, ratios: [0.5, 0.5])
        )
        .normalized()
    }

    public func removing(_ id: String) -> HerdrLayout? {
        switch self {
        case let .pane(pane):
            return pane == id ? nil : self
        case var .split(split):
            var children: [HerdrLayout] = []
            var ratios: [Double] = []
            for (child, ratio) in zip(split.children, split.ratios) {
                guard let kept = child.removing(id) else { continue }
                children.append(kept)
                ratios.append(ratio)
            }
            guard !children.isEmpty else { return nil }
            split.children = children
            split.ratios = ratios
            return HerdrLayout.split(split).normalized()
        }
    }

    public func replacing(_ old: String, with new: String) -> HerdrLayout {
        mapPanes { $0 == old ? new : $0 }
    }

    public func swapping(_ first: String, _ second: String) -> HerdrLayout {
        mapPanes { id in
            if id == first { return second }
            if id == second { return first }
            return id
        }
    }

    public func rotated() -> HerdrLayout {
        switch self {
        case .pane:
            return self
        case var .split(split):
            split.axis = split.axis == .horizontal ? .vertical : .horizontal
            split.children = split.children.map { $0.rotated() }
            return .split(split)
        }
    }

    public func mirrored(_ axis: SplitAxis) -> HerdrLayout {
        switch self {
        case .pane:
            return self
        case var .split(split):
            split.children = split.children.map { $0.mirrored(axis) }
            if split.axis == axis {
                split.children.reverse()
                split.ratios.reverse()
            }
            return .split(split)
        }
    }

    public func equalized() -> HerdrLayout {
        switch self {
        case .pane:
            return self
        case var .split(split):
            split.children = split.children.map { $0.equalized() }
            split.ratios = Array(
                repeating: 1.0 / Double(split.children.count), count: split.children.count)
            return .split(split)
        }
    }

    public func resizing(split id: UUID, index: Int, by change: Double) -> HerdrLayout {
        switch self {
        case .pane:
            return self
        case var .split(split):
            if split.id == id {
                guard index >= 0, index + 1 < split.ratios.count else { return self }
                let first = split.ratios[index] + change
                let second = split.ratios[index + 1] - change
                guard first >= Self.minimumShare, second >= Self.minimumShare else { return self }
                split.ratios[index] = first
                split.ratios[index + 1] = second
                return .split(split)
            }
            split.children = split.children.map { $0.resizing(split: id, index: index, by: change) }
            return .split(split)
        }
    }

    public func normalized() -> HerdrLayout {
        guard case let .split(split) = self else { return self }
        var children: [HerdrLayout] = []
        var ratios: [Double] = []
        for (child, ratio) in zip(split.children, split.ratios) {
            let child = child.normalized()
            if case let .split(inner) = child, inner.axis == split.axis {
                children.append(contentsOf: inner.children)
                ratios.append(contentsOf: inner.ratios.map { $0 * ratio })
            } else {
                children.append(child)
                ratios.append(ratio)
            }
        }
        if children.count == 1 { return children[0] }
        let total = ratios.reduce(0, +)
        ratios =
            total > 0
            ? ratios.map { $0 / total }
            : Array(repeating: 1.0 / Double(children.count), count: children.count)
        return .split(
            HerdrSplit(id: split.id, axis: split.axis, children: children, ratios: ratios))
    }

    public func content(in canvas: CGRect, gap: CGFloat) -> CGRect {
        paneCount > 1 ? canvas.insetBy(dx: gap, dy: gap) : canvas
    }

    public func paneFrames(in canvas: CGRect, gap: CGFloat) -> [String: CGRect] {
        frames(in: content(in: canvas, gap: gap), gap: paneCount > 1 ? gap : 0)
    }

    public func paneDividers(in canvas: CGRect, gap: CGFloat) -> [HerdrLayoutDivider] {
        dividers(in: content(in: canvas, gap: gap), gap: gap)
    }

    public func frames(in rect: CGRect, gap: CGFloat = 0) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        walk(in: rect, gap: gap) { node, frame in
            if case let .pane(id) = node { result[id] = frame }
        }
        return result
    }

    public func dividers(in rect: CGRect, gap: CGFloat) -> [HerdrLayoutDivider] {
        var result: [HerdrLayoutDivider] = []
        walk(in: rect, gap: gap) { node, frame in
            guard case let .split(split) = node else { return }
            let horizontal = split.axis == .horizontal
            let span = max(
                1,
                (horizontal ? frame.width : frame.height) - gap * CGFloat(split.children.count - 1))
            var offset = horizontal ? frame.minX : frame.minY
            for index in split.children.indices.dropLast() {
                offset += span * CGFloat(split.ratios[index])
                let divider =
                    horizontal
                    ? CGRect(x: offset, y: frame.minY, width: gap, height: frame.height)
                    : CGRect(x: frame.minX, y: offset, width: frame.width, height: gap)
                result.append(
                    HerdrLayoutDivider(
                        splitID: split.id, index: index, axis: split.axis, rect: divider,
                        span: span))
                offset += gap
            }
        }
        return result
    }

    public func neighbor(of id: String, toward side: InsertSide) -> String? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let frames = frames(in: unit)
        guard let origin = frames[id] else { return nil }
        let epsilon = 0.0001
        let candidates = frames.filter { entry in
            guard entry.key != id else { return false }
            let frame = entry.value
            switch side {
            case .left:
                return frame.maxX <= origin.minX + epsilon
                    && frame.maxY > origin.minY && frame.minY < origin.maxY
            case .right:
                return frame.minX >= origin.maxX - epsilon
                    && frame.maxY > origin.minY && frame.minY < origin.maxY
            case .top:
                return frame.maxY <= origin.minY + epsilon
                    && frame.maxX > origin.minX && frame.minX < origin.maxX
            case .bottom:
                return frame.minY >= origin.maxY - epsilon
                    && frame.maxX > origin.minX && frame.minX < origin.maxX
            }
        }
        return candidates.min { first, second in
            let firstDistance = distance(from: origin, to: first.value, side: side)
            let secondDistance = distance(from: origin, to: second.value, side: side)
            if abs(firstDistance - secondDistance) > epsilon {
                return firstDistance < secondDistance
            }
            if abs(first.value.minY - second.value.minY) > epsilon {
                return first.value.minY < second.value.minY
            }
            return first.value.minX < second.value.minX
        }?.key
    }

    public func geometryMatches(_ other: HerdrLayout, tolerance: CGFloat = 0.01) -> Bool {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let mine = Self.sorted(frames(in: unit).values)
        let theirs = Self.sorted(other.frames(in: unit).values)
        guard mine.count == theirs.count else { return false }
        return zip(mine, theirs).allSatisfy { first, second in
            abs(first.minX - second.minX) <= tolerance && abs(first.minY - second.minY) <= tolerance
                && abs(first.width - second.width) <= tolerance
                && abs(first.height - second.height) <= tolerance
        }
    }

    private static func sorted<S: Sequence>(_ frames: S) -> [CGRect] where S.Element == CGRect {
        frames.sorted { first, second in
            if abs(first.minY - second.minY) > 0.0001 { return first.minY < second.minY }
            return first.minX < second.minX
        }
    }

    private func distance(from origin: CGRect, to frame: CGRect, side: InsertSide) -> CGFloat {
        let gapDistance: CGFloat =
            switch side {
            case .left: origin.minX - frame.maxX
            case .right: frame.minX - origin.maxX
            case .top: origin.minY - frame.maxY
            case .bottom: frame.minY - origin.maxY
            }
        let offAxis: CGFloat =
            side.axis == .horizontal
            ? abs(frame.midY - origin.midY) : abs(frame.midX - origin.midX)
        return gapDistance * 10 + offAxis
    }

    private func mapPanes(_ transform: (String) -> String) -> HerdrLayout {
        switch self {
        case let .pane(id):
            return .pane(transform(id))
        case var .split(split):
            split.children = split.children.map { $0.mapPanes(transform) }
            return .split(split)
        }
    }

    private func walk(
        in rect: CGRect, gap: CGFloat, _ visit: (HerdrLayout, CGRect) -> Void
    ) {
        visit(self, rect)
        guard case let .split(split) = self else { return }
        let horizontal = split.axis == .horizontal
        let count = CGFloat(split.children.count)
        let span = max(0, (horizontal ? rect.width : rect.height) - gap * (count - 1))
        var offset = horizontal ? rect.minX : rect.minY
        for (index, child) in split.children.enumerated() {
            let length = span * CGFloat(split.ratios[index])
            let frame =
                horizontal
                ? CGRect(x: offset, y: rect.minY, width: length, height: rect.height)
                : CGRect(x: rect.minX, y: offset, width: rect.width, height: length)
            child.walk(in: frame, gap: gap, visit)
            offset += length + gap
        }
    }
}
