import Adwaita
import EdithCore
import Foundation

let ubuntuCapabilities = PlatformCapabilities.ubuntu

struct DetailRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let iconName: String
}

struct RowList: View {
    var title: String
    var rows: [DetailRow]

    var view: Body {
        VStack {
            Text(title)
                .captionHeading()
                .halign(.start)
                .padding(6, .bottom)
            List(rows, selection: nil) { row in
                HStack {
                    Text(row.title)
                        .halign(.start)
                        .hexpand()
                    Text(row.detail)
                        .caption()
                        .dimLabel()
                        .halign(.end)
                }
                .padding(12)
            }
            .boxedList()
        }
        .padding(12, .bottom)
    }
}

struct HomePage: View {
    var view: Body {
        ScrollView {
            VStack {
                StatusPage(
                    "Edith for Ubuntu",
                    icon: .custom(name: "go-home-symbolic"),
                    description: "The GTK interface is native. The features behind it are "
                        + "still being ported from macOS."
                )
                RowList(title: "Port status", rows: summaryRows)
            }
            .frame(maxWidth: 720)
            .padding()
        }
    }

    private var summaryRows: [DetailRow] {
        let reports = ExtensionAvailabilityReport.reports(for: ubuntuCapabilities)
        let workingExtensions = reports.filter { $0.blockers.isEmpty }.count
        let supported = PlatformCapability.allCases.filter {
            ubuntuCapabilities.state(for: $0).isSupported
        }
        return [
            DetailRow(
                id: "extensions", title: "Extensions",
                detail: "\(workingExtensions) of \(reports.count) working",
                iconName: "application-x-addon-symbolic"),
            DetailRow(
                id: "capabilities", title: "Capabilities",
                detail: "\(supported.count) of \(PlatformCapability.allCases.count) supported",
                iconName: "computer-symbolic"),
        ]
    }
}

struct ExtensionsPage: View {
    var view: Body {
        ScrollView {
            VStack {
                RowList(title: "Agent", rows: rows(in: .agent))
                RowList(title: "System", rows: rows(in: .system))
                RowList(title: "Media", rows: rows(in: .media))
                RowList(title: "Utilities", rows: rows(in: .utilities))
            }
            .frame(maxWidth: 720)
            .padding()
        }
    }

    private func rows(in group: ExtensionGroup) -> [DetailRow] {
        ExtensionAvailabilityReport.reports(for: ubuntuCapabilities)
            .filter { $0.entry.group == group }
            .map {
                DetailRow(
                    id: $0.entry.id, title: $0.entry.title,
                    detail: $0.availability.summary, iconName: "application-x-addon-symbolic")
            }
    }
}

struct CapabilitiesPage: View {
    var view: Body {
        ScrollView {
            VStack {
                RowList(title: "Platform capabilities", rows: rows)
            }
            .frame(maxWidth: 720)
            .padding()
        }
    }

    private var rows: [DetailRow] {
        PlatformCapability.allCases.map { capability in
            DetailRow(
                id: capability.rawValue, title: capability.title,
                detail: ubuntuCapabilities.state(for: capability).summary,
                iconName: "computer-symbolic")
        }
    }
}

struct PortStatusPage: View {
    var destination: NavigationDestination

    private var report: ExtensionAvailabilityReport? {
        guard let id = destination.extensionID else { return nil }
        return ExtensionAvailabilityReport.reports(for: ubuntuCapabilities)
            .first { $0.entry.id == id }
    }

    var view: Body {
        ScrollView {
            VStack {
                StatusPage(
                    destination.title,
                    icon: .custom(name: destination.freedesktopIconName),
                    description: report?.entry.subtitle
                        ?? "This section has no Ubuntu implementation yet."
                )
                if let report, !report.blockers.isEmpty {
                    RowList(title: "Still needed on Ubuntu", rows: blockerRows(report))
                }
            }
            .frame(maxWidth: 720)
            .padding()
        }
    }

    private func blockerRows(_ report: ExtensionAvailabilityReport) -> [DetailRow] {
        report.blockers.map {
            DetailRow(
                id: $0.capability.rawValue, title: $0.capability.title,
                detail: $0.state.summary, iconName: "builder-build-symbolic")
        }
    }
}

struct AboutPage: View {
    var view: Body {
        ScrollView {
            VStack {
                StatusPage(
                    "Edith",
                    icon: .custom(name: "help-about-symbolic"),
                    description: "A native GTK 4 and libadwaita interface sharing its core "
                        + "with the macOS app."
                )
                RowList(title: "Locations", rows: locationRows)
            }
            .frame(maxWidth: 720)
            .padding()
        }
    }

    private var locationRows: [DetailRow] {
        let directories = AppDirectories.current
        return [
            DetailRow(
                id: "configuration", title: "Configuration",
                detail: directories.configuration.path, iconName: "folder-symbolic"),
            DetailRow(
                id: "data", title: "Data", detail: directories.data.path,
                iconName: "folder-symbolic"),
            DetailRow(
                id: "cache", title: "Cache", detail: directories.cache.path,
                iconName: "folder-symbolic"),
            DetailRow(
                id: "runtime", title: "Runtime", detail: directories.runtime.path,
                iconName: "folder-symbolic"),
        ]
    }
}
