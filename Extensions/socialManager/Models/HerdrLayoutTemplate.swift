import CoreGraphics
import Foundation

public struct HerdrSavedArrangement: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var shape: HerdrLayout

    public init(id: UUID = UUID(), name: String, layout: HerdrLayout) {
        self.id = id
        self.name = name
        shape = layout.shape()
    }

    public var count: Int { shape.paneCount }
}

public enum HerdrLayoutTemplate: Hashable, Sendable, Identifiable {
    case builtIn(HerdrArrangement)
    case saved(HerdrSavedArrangement)

    public var id: String {
        switch self {
        case let .builtIn(arrangement): "builtIn:\(arrangement.rawValue)"
        case let .saved(saved): "saved:\(saved.id.uuidString)"
        }
    }

    public var title: String {
        switch self {
        case let .builtIn(arrangement): arrangement.title
        case let .saved(saved): saved.name
        }
    }

    public var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    public func layout(_ ids: [String]) -> HerdrLayout? {
        switch self {
        case let .builtIn(arrangement):
            return arrangement.layout(ids)
        case let .saved(saved):
            guard ids.count == saved.count else { return nil }
            return saved.shape.filled(with: ids)
        }
    }

    public func slotFrames(count: Int, in rect: CGRect, gap: CGFloat) -> [CGRect] {
        let slots = HerdrArrangement.placeholders(count)
        guard let layout = layout(slots) else { return [] }
        let frames = layout.frames(in: rect, gap: gap)
        return slots.compactMap { frames[$0] }
    }

    public static func all(for count: Int, saved: [HerdrSavedArrangement])
        -> [HerdrLayoutTemplate]
    {
        saved.filter { $0.count == count }.map(HerdrLayoutTemplate.saved)
            + HerdrArrangement.options(for: count).map(HerdrLayoutTemplate.builtIn)
    }

    public static func matching(_ layout: HerdrLayout, saved: [HerdrSavedArrangement])
        -> HerdrLayoutTemplate?
    {
        let count = layout.paneCount
        return all(for: count, saved: saved).first { template in
            template.layout(HerdrArrangement.placeholders(count))?.geometryMatches(layout) == true
        }
    }
}
