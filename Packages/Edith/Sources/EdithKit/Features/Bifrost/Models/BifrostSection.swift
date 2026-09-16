import CoreGraphics
import Foundation
import SwiftUI

public struct BifrostSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let results: [BifrostResult]

    public init(id: String, title: String, results: [BifrostResult]) {
        self.id = id
        self.title = title
        self.results = results
    }
}

public enum BifrostSectionBuilder {
    public static let recentTitle = "Recent"

    public static func sections(from results: [BifrostResult], query: String) -> [BifrostSection] {
        var built: [BifrostSection] = []
        var current: [BifrostResult] = []
        var key: String?
        var kind: BifrostResultKind?
        for result in results {
            let resultKey = result.group ?? result.kind.rawValue
            if resultKey != key, let key, let kind, !current.isEmpty {
                built.append(section(kind: kind, key: key, results: current, query: query))
                current = []
            }
            key = resultKey
            kind = result.kind
            current.append(result)
        }
        if let key, let kind, !current.isEmpty {
            built.append(section(kind: kind, key: key, results: current, query: query))
        }
        return built
    }

    private static func section(
        kind: BifrostResultKind, key: String, results: [BifrostResult], query: String
    ) -> BifrostSection {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let grouped = results.first?.group
        let title = grouped ?? (kind == .application && trimmed.isEmpty ? recentTitle : kind.title)
        return BifrostSection(id: key, title: title, results: results)
    }
}

public enum BifrostPanelMetrics {
    public static let width: CGFloat = 750
    public static let headerHeight: CGFloat = 54
    public static let sectionHeaderHeight: CGFloat = 26
    public static let rowHeight: CGFloat = 44
    public static let footerHeight: CGFloat = 36
    public static let listPadding: CGFloat = 6
    public static let answerHeight: CGFloat = 132
    public static let cornerRadius: CGFloat = 14
    public static let topFraction: CGFloat = 0.147
    public static let modeHeight: CGFloat = 470
    public static let detailFraction: CGFloat = 0.52
    public static let bottomFraction: CGFloat = 0.084

    public static func defaultAnchorTop(in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: (visibleFrame.maxY - visibleFrame.height * topFraction).rounded())
    }
    public static let scrimOpacity: Double = 0.84

    public static var scrim: Color { Color.black.opacity(scrimOpacity) }

    public static var nominalHeight: CGFloat {
        headerHeight + listPadding + footerHeight + sectionHeaderHeight + 5 * rowHeight
    }

    public static func isInDragHandle(point: CGPoint, frame: CGRect) -> Bool {
        guard frame.contains(point) else { return false }
        return point.y >= frame.maxY - headerHeight
    }

    public static func moved(_ frame: CGRect, by delta: CGSize) -> CGRect {
        CGRect(
            x: frame.origin.x + delta.width, y: frame.origin.y + delta.height,
            width: frame.width, height: frame.height)
    }

    public static func frame(anchorTop: CGPoint, height: CGFloat) -> CGRect {
        CGRect(x: anchorTop.x, y: anchorTop.y - height, width: width, height: height)
    }

    public static func height(for sections: [BifrostSection]) -> CGFloat {
        guard !sections.isEmpty else { return headerHeight }
        var height = headerHeight + listPadding + footerHeight
        for section in sections {
            height += sectionHeaderHeight
            for result in section.results {
                height += result.answer == nil ? rowHeight : answerHeight
            }
        }
        return height
    }
}

public struct BifrostGuideLines: Equatable, Sendable {
    public static func positions(in frame: CGRect) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        let anchor = BifrostPanelMetrics.defaultAnchorTop(in: frame)
        return (
            [anchor.x, anchor.x + BifrostPanelMetrics.width],
            [anchor.y, frame.minY + frame.height * BifrostPanelMetrics.bottomFraction]
        )
    }

    public static func fractions(in frame: CGRect) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        let lines = positions(in: frame)
        return (
            lines.vertical.map { ($0 - frame.minX) / frame.width },
            lines.horizontal.map { ($0 - frame.minY) / frame.height }
        )
    }
}
