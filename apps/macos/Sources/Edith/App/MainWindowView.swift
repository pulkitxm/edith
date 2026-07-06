import EdithKit
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case dashboard, usage, music, calendar, system, general, permissions, backup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .usage: return "Usage"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .system: return "System"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .backup: return "Backup"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .usage: return "gauge.with.dots.needle.67percent"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .system: return "switch.2"
        case .general: return "gearshape"
        case .permissions: return "checkmark.shield"
        case .backup: return "icloud"
        }
    }
}

struct MainWindowView: View {
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var selectionRaw =
        MainSection.dashboard.rawValue

    private var selection: Binding<MainSection?> {
        Binding(
            get: { MainSection(rawValue: selectionRaw) },
            set: { selectionRaw = $0?.rawValue ?? MainSection.dashboard.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("Home") {
                    row(.dashboard)
                }
                Section("Modules") {
                    row(.usage)
                    row(.music)
                    row(.calendar)
                    row(.system)
                }
                Section("App") {
                    row(.general)
                    row(.permissions)
                    row(.backup)
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            detail(for: selection.wrappedValue ?? .dashboard)
        }
    }

    private func row(_ section: MainSection) -> some View {
        Label(section.title, systemImage: section.icon).tag(section)
    }

    @ViewBuilder
    private func detail(for section: MainSection) -> some View {
        switch section {
        case .dashboard: DashboardView()
        case .usage: UsagePane()
        case .music: MusicPane()
        case .calendar: CalendarPane()
        case .system: SystemPane()
        case .general: GeneralPane()
        case .permissions: MainPermissionsPane()
        case .backup: BackupPane()
        }
    }
}
