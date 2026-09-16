import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostSectionTests {
    private func result(_ kind: BifrostResultKind, _ title: String) -> BifrostResult {
        BifrostResult(
            id: kind.rawValue + ":" + title, kind: kind, title: title, subtitle: "",
            symbolName: "circle", action: .copy(text: title), score: 1)
    }

    @Test func consecutiveKindsBecomeOneSectionEach() {
        let sections = BifrostSectionBuilder.sections(
            from: [
                result(.calculation, "4"), result(.application, "Safari"),
                result(.application, "Notes"), result(.command, "Clipboard History"),
            ], query: "2+2")

        #expect(sections.map(\.title) == ["Calculator", "Applications", "Commands"])
        #expect(sections[1].results.count == 2)
    }

    @Test func anEmptyQueryCallsTheApplicationSectionRecent() {
        let sections = BifrostSectionBuilder.sections(
            from: [result(.application, "Safari")], query: "  ")

        #expect(sections.map(\.title) == [BifrostSectionBuilder.recentTitle])
    }

    @Test func noResultsMeanNoSections() {
        #expect(BifrostSectionBuilder.sections(from: [], query: "x").isEmpty)
    }

    @Test func theBarIsOnlyItsFieldUntilSomethingMatches() {
        #expect(BifrostPanelMetrics.height(for: []) == BifrostPanelMetrics.headerHeight)
    }

    @Test func everySectionAddsItsHeaderAndItsRows() {
        let sections = BifrostSectionBuilder.sections(
            from: [result(.calculation, "4"), result(.application, "Safari")], query: "2+2")
        let expected =
            BifrostPanelMetrics.headerHeight + BifrostPanelMetrics.listPadding
            + BifrostPanelMetrics.footerHeight + 2 * BifrostPanelMetrics.sectionHeaderHeight
            + 2 * BifrostPanelMetrics.rowHeight

        #expect(BifrostPanelMetrics.height(for: sections) == expected)
    }
}

@Suite struct BifrostCommandCatalogTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "BifrostCommandCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func everyCommandNamesARegisteredAbilityOrNone() {
        for command in BifrostCommandCatalog.commands {
            guard let abilityID = command.abilityID else { continue }
            #expect(
                ExtensionRegistry.entry(abilityID) != nil,
                "\(command.id) points at \(abilityID), which is not an ability")
        }
    }

    @Test func commandIdentifiersAreUnique() {
        let identifiers = BifrostCommandCatalog.commands.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func aCommandAppearsOnlyWhileItsAbilityIsOn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let core = BifrostCommandCatalog.available(in: defaults)
        #expect(core.map(\.id) == ["panel.open"])

        defaults.set(true, forKey: AppStorageKeys.Suites.desk)
        defaults.set(true, forKey: AppStorageKeys.Emoji.enabled)

        let withEmoji = BifrostCommandCatalog.available(in: defaults)
        #expect(withEmoji.contains { $0.id == "emoji.pick" })
        #expect(!withEmoji.contains { $0.id == "clipboard.open" })
    }

    @Test func everyCommandCarriesItsOwnNotification() {
        let names = BifrostCommandCatalog.commands.map(\.notification.rawValue)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("com.pulkit.edith.") })
    }
}

@Suite struct BifrostGuideLineTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

    @Test func theBarOpensCentredAndHighOnTheScreen() {
        let anchor = BifrostPanelMetrics.defaultAnchorTop(in: screen)

        #expect(anchor.x == (screen.midX - BifrostPanelMetrics.width / 2).rounded())
        #expect(
            anchor.y == (screen.maxY - screen.height * BifrostPanelMetrics.topFraction).rounded())
        #expect(screen.maxY - anchor.y < screen.height / 4)
    }

    @Test func guidesMarkWhereTheBarBelongs() {
        let anchor = BifrostPanelMetrics.defaultAnchorTop(in: screen)
        let positions = BifrostGuideLines.positions(in: screen)

        #expect(positions.vertical == [anchor.x, anchor.x + BifrostPanelMetrics.width])
        #expect(positions.horizontal.first == anchor.y)
    }

    @Test func guidesStayInsideTheFrameTheyMark() {
        let positions = BifrostGuideLines.positions(in: screen)

        #expect(positions.vertical.allSatisfy { screen.minX < $0 && $0 < screen.maxX })
        #expect(positions.horizontal.allSatisfy { screen.minY < $0 && $0 < screen.maxY })
    }

    @Test func aSecondScreenGetsItsOwnAnchor() {
        let secondary = CGRect(x: 1728, y: 200, width: 1512, height: 900)
        let anchor = BifrostPanelMetrics.defaultAnchorTop(in: secondary)

        #expect(anchor.x > secondary.minX)
        #expect(anchor.x + BifrostPanelMetrics.width < secondary.maxX)
        #expect(anchor.y < secondary.maxY)
    }
}

@Suite struct BifrostPanelFrameTests {
    @Test func growingTheBarKeepsItsTopEdgeWhereItWas() {
        let top = CGPoint(x: 200, y: 900)
        let collapsed = BifrostPanelMetrics.frame(
            anchorTop: top, height: BifrostPanelMetrics.headerHeight)
        let grown = BifrostPanelMetrics.frame(anchorTop: top, height: 420)

        #expect(collapsed.maxY == top.y)
        #expect(grown.maxY == top.y)
        #expect(collapsed.minX == grown.minX)
        #expect(grown.height == 420)
        #expect(grown.width == BifrostPanelMetrics.width)
    }

    @Test func shrinkingTheBarKeepsItsTopEdgeWhereItWas() {
        let top = CGPoint(x: 0, y: 500)
        let tall = BifrostPanelMetrics.frame(anchorTop: top, height: 400)
        let short = BifrostPanelMetrics.frame(anchorTop: top, height: 100)

        #expect(tall.maxY == short.maxY)
        #expect(short.minY > tall.minY)
    }
}

@Suite struct BifrostDragTests {
    private let frame = CGRect(x: 100, y: 400, width: 640, height: 300)

    @Test func onlyTheHeaderStripStartsADrag() {
        let header = CGPoint(x: 400, y: frame.maxY - 10)
        let list = CGPoint(x: 400, y: frame.minY + 10)

        #expect(BifrostPanelMetrics.isInDragHandle(point: header, frame: frame))
        #expect(!BifrostPanelMetrics.isInDragHandle(point: list, frame: frame))
    }

    @Test func aPointOutsideTheBarNeverStartsADrag() {
        #expect(
            !BifrostPanelMetrics.isInDragHandle(
                point: CGPoint(x: 10, y: frame.maxY - 10), frame: frame))
        #expect(
            !BifrostPanelMetrics.isInDragHandle(
                point: CGPoint(x: 400, y: frame.maxY + 40), frame: frame))
    }

    @Test func movingKeepsTheSizeAndShiftsTheOrigin() {
        let moved = BifrostPanelMetrics.moved(frame, by: CGSize(width: -30, height: 12))

        #expect(moved.origin == CGPoint(x: 70, y: 412))
        #expect(moved.size == frame.size)
    }
}
