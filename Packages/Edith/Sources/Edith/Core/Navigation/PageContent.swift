import EdithKit
import SwiftUI

struct PageContent: View {
    let destination: MainDestination
    let updater: UpdaterModel
    @Environment(\.windowSessionOwner) private var sessions

    init(_ destination: MainDestination, updater: UpdaterModel) {
        self.destination = destination
        self.updater = updater
    }

    var body: some View {
        Group {
            switch destination {
            case .home: HomePage()
            case .machines: MachinesPage()
            case .docs: DocsScreen()
            case .agents: SuiteLandingPage(suite: SuiteRegistry.suite(.agents))
            case .dashboard: DashboardView()
            case .herdr: HerdrPage()
            case .quinjet: QuinjetPage()
            case .companion: CompanionPage(session: sessions?.companion)
            case .plugins: PluginsPage()
            case .appMaintenance: AppMaintenanceView(model: sessions?.maintenance)
            case .blitztree: BlitzTreePage(model: sessions?.blitzTree)
            case .system: SuiteLandingPage(suite: SuiteRegistry.suite(.system))
            case .runningApps: SystemPage(model: sessions?.runningApps)
            case .desk: SuiteLandingPage(suite: SuiteRegistry.suite(.desk))
            case .media: SuiteLandingPage(suite: SuiteRegistry.suite(.media))
            case .studio: StudioPage()
            case .latex: LaTeXPage()
            case .timeLapse: TimeLapsePage()
            case .downloads: DownloadSheet(isPage: true)
            case .music: MusicPage()
            case .calendar: CalendarPage()
            case .virtualCamera: VirtualCameraPage()
            case .data: SuiteLandingPage(suite: SuiteRegistry.suite(.data))
            case .database: DatabasePage(session: sessions?.database)
            case .attention: AttentionPage(model: sessions?.attention)
            case .seoAudit: SEOAuditPage()
            case .codeStats: CodeStatsPage(model: sessions?.codeStats)
            case .extensions: ExtensionsPane(model: sessions?.extensions)
            case .settings: SettingsPane(updater: updater)
            case .about: AboutPane()
            }
        }
        .environment(\.pageLocation, destination.rawValue)
    }
}
