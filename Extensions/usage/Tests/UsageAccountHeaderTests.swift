import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite struct UsageAccountHeaderTests {
    private func accounts() -> [ClaudeAccountLimits] {
        ["First synthetic account", "Second synthetic account"].map {
            .init(
                id: UUID(), name: $0,
                limits: .init(
                    provider: .claude, session: .init(percent: 10, resetsAt: nil),
                    week: .init(percent: 95, resetsAt: nil)), refreshedAt: Date())
        }
    }

    @Test func stackedHeadersPreserveShortLabelsAndMaskIdentityAndRemainingCount() {
        let source = accounts()
        let groups = MenuBarLimits.accountGroups(
            source, selectedID: nil, slots: [.session, .week], masked: false)
        #expect(groups.map(\.accountHeader) == source.map { String($0.name.prefix(16)) })
        #expect(groups.map(\.accountLabel) == source.map { String($0.name.prefix(8)) })
        let hidden = MenuBarLimits.accountGroups(
            source + accounts(), selectedID: nil, slots: [.session, .week], masked: true)
        #expect(hidden.allSatisfy { $0.accountHeader == "Account" && $0.accountLabel == "Account" })
        #expect(hidden.allSatisfy { $0.remainingAccounts == 0 })
    }

    @Test func namedGroupsHonorCustomLabelRiskMissingAndCountColorsWithOneLogo() throws {
        let suite = "usage-account-header." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("custom", forKey: AppStorageKeys.MenuBar.colorMode)
        defaults.set("FFFFFF", forKey: AppStorageKeys.MenuBar.subColorHex)
        defaults.set("123456", forKey: AppStorageKeys.MenuBar.lowColorHex)
        defaults.set("FEDCBA", forKey: AppStorageKeys.MenuBar.highColorHex)
        defaults.set(false, forKey: AppStorageKeys.General.smartColor)
        let groups = MenuBarLimits.accountGroups(
            accounts(), selectedID: nil, slots: [.session, .week, .fable], masked: false)
        let rendered = LimitsStatusItem.stackedGroups(groups, defaults: defaults)
        #expect(rendered.count == 2)
        #expect(rendered[0].logo != nil)
        #expect(rendered[1].logo == nil)
        #expect(rendered.map(\.header) == groups.map(\.accountHeader))
        #expect(rendered[0].columns.map(\.label) == ["5h", "7d", "F"])
        #expect(rendered[0].headerColor == LimitsStatusItem.nsColor(hex: "FFFFFF"))
        #expect(rendered[0].columns[0].valueColor == LimitsStatusItem.nsColor(hex: "123456"))
        #expect(rendered[0].columns[1].valueColor == LimitsStatusItem.nsColor(hex: "FEDCBA"))
        #expect(rendered[0].columns[2].valueColor == LimitsStatusItem.nsColor(hex: "FFFFFF"))
        #expect(
            rendered.flatMap(\.columns).allSatisfy {
                $0.labelColor == LimitsStatusItem.nsColor(hex: "FFFFFF")
            })
        let many = MenuBarLimits.accountGroups(
            accounts() + accounts(), selectedID: nil, slots: [.session], masked: false)
        let count = LimitsStatusItem.stackedGroups(many, defaults: defaults)[0].columns.last
        #expect(count?.label == "accounts")
        #expect(count?.value == "+3")
        #expect(count?.valueColor == LimitsStatusItem.nsColor(hex: "FFFFFF"))
        let hidden = MenuBarLimits.accountGroups(
            accounts(), selectedID: nil, slots: [.session, .week], masked: true)
        let masked = LimitsStatusItem.stackedGroups(hidden, defaults: defaults)
        #expect(masked.allSatisfy { $0.header == "Account" })
        #expect(
            masked.flatMap(\.columns).allSatisfy {
                $0.value == "·" && $0.valueColor == $0.labelColor
            })
        defaults.set("auto", forKey: AppStorageKeys.MenuBar.colorMode)
        let automatic = LimitsStatusItem.stackedGroups(groups, defaults: defaults)
        #expect(automatic[0].headerColor == .secondaryLabelColor)
        #expect(automatic[0].columns[0].valueColor == .systemGreen)
    }

    @Test func namedGroupsUseResetPacingForSmartRiskColor() throws {
        let suite = "usage-account-pacing." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("custom", forKey: AppStorageKeys.MenuBar.colorMode)
        defaults.set("FEDCBA", forKey: AppStorageKeys.MenuBar.highColorHex)
        defaults.set(true, forKey: AppStorageKeys.General.smartColor)
        let account = ClaudeAccountLimits(
            id: UUID(), name: "Synthetic",
            limits: .init(
                provider: .claude,
                session: .init(percent: 90, resetsAt: Date().addingTimeInterval(5 * 3600)),
                week: nil), refreshedAt: Date())
        let groups = MenuBarLimits.accountGroups(
            [account], selectedID: nil, slots: [.session], masked: false)
        #expect(
            LimitsStatusItem.stackedGroups(groups, defaults: defaults)[0].columns[0].valueColor
                == LimitsStatusItem.nsColor(hex: "FEDCBA"))
    }

    @Test func headerWidthAndValueWidthBothContributeWithoutChangingProviderColumns() {
        func view(_ header: String?, _ value: String) -> StackedLimitsView {
            let view = StackedLimitsView()
            view.groups = [
                .init(
                    logo: nil,
                    columns: [
                        .init(
                            label: "5h", value: value, valueColor: .labelColor,
                            labelColor: .labelColor)
                    ], header: header)
            ]
            return view
        }
        #expect(view("Long account header", "1").desiredWidth > view("A", "1").desiredWidth)
        #expect(view("A", "100").desiredWidth > view("A", "1").desiredWidth)
        #expect(view(nil, "100").desiredWidth > view(nil, "1").desiredWidth)
        #expect(view(nil, "1").groups.first?.header == nil)
    }
}
