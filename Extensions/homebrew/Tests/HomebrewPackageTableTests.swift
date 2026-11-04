import AppKit
import EdithExtensionUI
import Testing

@testable import HomebrewExtension

@MainActor @Suite struct HomebrewPackageTableTests {
    @Test func calendarVersionUpgradesFitTheVersionColumn() {
        let package = HomebrewPackage(
            kind: .formula, name: "certifi", displayName: "certifi",
            installedVersions: ["2026.7.22"], currentVersion: "2026.10.13", outdated: true)
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: UIScale.pt(NSFont.preferredFont(forTextStyle: .callout).pointSize),
            weight: .regular)
        let width = (package.versionSummary as NSString).size(withAttributes: [.font: font]).width
        let cellPadding = 12.0
        #expect(width + cellPadding <= UIScale.pt(HomebrewPackageTable.versionWidth))
    }

    @Test func upgradeAndUninstallFitTheActionsColumn() {
        let font = NSFont.systemFont(
            ofSize: UIScale.pt(NSFont.preferredFont(forTextStyle: .callout).pointSize))
        let labels = ["Upgrade", "Uninstall"].map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        let buttonPadding = 24.0
        let spacing = 8.0
        let required = labels.reduce(0) { $0 + $1 + buttonPadding } + spacing + 12
        #expect(required <= UIScale.pt(HomebrewPackageTable.actionsWidth))
    }
}
