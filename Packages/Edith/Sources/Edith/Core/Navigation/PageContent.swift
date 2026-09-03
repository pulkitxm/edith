import EdithKit
import SwiftUI

struct PageContent: View {
    let destination: MainDestination
    let updater: UpdaterModel

    init(_ destination: MainDestination, updater: UpdaterModel) {
        self.destination = destination
        self.updater = updater
    }

    var body: some View {
        switch destination {
        case .home: HomePage()
        case .machines: MachinesPage()
        case .agents: SuiteLandingPage(suite: SuiteRegistry.suite(.agents))
        case .dashboard: DashboardView()
        case .herdr: HerdrPage()
        case .quinjet: QuinjetPage()
        case .companion: CompanionPage()
        case .appMaintenance: AppMaintenanceView()
        case .system: SuiteLandingPage(suite: SuiteRegistry.suite(.system))
        case .runningApps: SystemPage()
        case .desk: SuiteLandingPage(suite: SuiteRegistry.suite(.desk))
        case .media: SuiteLandingPage(suite: SuiteRegistry.suite(.media))
        case .music: MusicPage()
        case .calendar: CalendarPage()
        case .data: SuiteLandingPage(suite: SuiteRegistry.suite(.data))
        case .database: DatabasePage()
        case .attention: AttentionPage()
        case .seoAudit: SEOAuditPage()
        case .extensions: ExtensionsPane()
        case .settings: SettingsPane(updater: updater)
        case .about: AboutPane()
        }
    }
}
