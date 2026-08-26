import Foundation
import Testing

@Suite struct SettingsLayoutTests {
    @Test func settingsUsesPrimaryNavigationAndFullWidthContent() throws {
        let settingsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/GeneralPane.swift")
        let navigationURL =
            settingsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Navigation/MainNavigationView.swift")
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        let navigation = try String(contentsOf: navigationURL, encoding: .utf8)

        #expect(navigation.contains("ForEach(SettingsPane.Tab.allCases"))
        #expect(navigation.contains("SettingsSidebarRow"))
        #expect(navigation.contains("settingsCategoriesExpanded.toggle()"))
        #expect(navigation.contains("CollapsibleSidebarLayout"))
        #expect(navigation.contains(".clipped()"))
        #expect(navigation.contains("disclosureAction: item == .settings"))
        #expect(navigation.contains(".zIndex(1)"))
        #expect(!navigation.contains(".move(edge: .top).combined(with: .opacity)"))
        #expect(navigation.contains("rotationEffect(.degrees(disclosureExpanded ? 90 : 0))"))
        #expect(navigation.contains(".padding(.top, UIScale.pt(6))"))
        #expect(settings.contains(".pickerStyle(.menu)"))
        #expect(!settings.contains(".pickerStyle(.segmented)"))
        #expect(!settings.contains("List(selection: tab)"))
        #expect(settings.contains("case .permissions: .infinity"))
        #expect(settings.contains("UIScale.pt(1180)"))
        #expect(settings.contains("alignment: .topLeading"))
    }

    @Test func everyCategoryHasAnIconAndSummary() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/GeneralPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for category in ["general", "permissions", "shortcuts", "terminal", "icloud", "updates"] {
            #expect(source.contains("case .\(category): return"))
        }
        #expect(source.contains("tab.wrappedValue.summary"))
    }

    @Test func permissionCardsUseTheAvailableWidthAdaptively() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/PermissionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("LazyVGrid(columns: columns"))
        #expect(source.contains(".adaptive(minimum:"))
        #expect(source.contains("maxWidth: .infinity"))
    }
}
