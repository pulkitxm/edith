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
    @Test func guidesDivideTheVisibleFrame() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let positions = BifrostGuideLines.positions(in: frame)

        #expect(positions.vertical == [300, 500, 700])
        #expect(positions.horizontal == [170, 350, 530])
    }

    @Test func guidesStayInsideTheFrameTheyDivide() {
        let frame = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let positions = BifrostGuideLines.positions(in: frame)

        #expect(positions.vertical.allSatisfy { frame.minX < $0 && $0 < frame.maxX })
        #expect(positions.horizontal.allSatisfy { frame.minY < $0 && $0 < frame.maxY })
    }
}
