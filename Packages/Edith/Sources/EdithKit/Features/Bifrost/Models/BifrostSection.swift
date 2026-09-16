import CoreGraphics
import Foundation

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
        var kind: BifrostResultKind?
        for result in results {
            if result.kind != kind, let kind, !current.isEmpty {
                built.append(section(kind: kind, results: current, query: query))
                current = []
            }
            kind = result.kind
            current.append(result)
        }
        if let kind, !current.isEmpty {
            built.append(section(kind: kind, results: current, query: query))
        }
        return built
    }

    private static func section(
        kind: BifrostResultKind, results: [BifrostResult], query: String
    ) -> BifrostSection {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = kind == .application && trimmed.isEmpty ? recentTitle : kind.title
        return BifrostSection(id: kind.rawValue, title: title, results: results)
    }
}

public enum BifrostPanelMetrics {
    public static let width: CGFloat = 640
    public static let headerHeight: CGFloat = 54
    public static let sectionHeaderHeight: CGFloat = 26
    public static let rowHeight: CGFloat = 44
    public static let footerHeight: CGFloat = 36
    public static let listPadding: CGFloat = 6
    public static let cornerRadius: CGFloat = 14

    public static func height(for sections: [BifrostSection]) -> CGFloat {
        guard !sections.isEmpty else { return headerHeight }
        var height = headerHeight + listPadding + footerHeight
        for section in sections {
            height += sectionHeaderHeight + CGFloat(section.results.count) * rowHeight
        }
        return height
    }
}

public struct BifrostGuideLines: Equatable, Sendable {
    public static let vertical: [CGFloat] = [0.25, 0.5, 0.75]
    public static let horizontal: [CGFloat] = [0.2, 0.5, 0.8]

    public static func positions(in frame: CGRect) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        (
            vertical.map { frame.minX + frame.width * $0 },
            horizontal.map { frame.minY + frame.height * $0 }
        )
    }
}
