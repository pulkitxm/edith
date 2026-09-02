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
        case .dashboard: DashboardView()
        case .herdr: HerdrPage()
        case .quinjet: QuinjetPage()
        case .companion: CompanionPage()
        case .appMaintenance: AppMaintenanceView()
        case .system: SystemPage()
        case .music: MusicPage()
        case .calendar: CalendarPage()
        case .database: DatabasePage()
        case .attention: AttentionPage()
        case .seoAudit: SEOAuditPage()
        case .extensions: ExtensionsPane()
        case .settings: SettingsPane(updater: updater)
        case .about: AboutPane()
        }
    }
}
