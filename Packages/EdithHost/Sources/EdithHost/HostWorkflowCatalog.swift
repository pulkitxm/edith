import EdithHostCore
import ExtensionMarketplace
import Foundation

enum HostWorkflow: String, CaseIterable, Identifiable, Sendable {
    case agentic, creative, developer, essentials, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .agentic: "sparkles"
        case .creative: "paintpalette"
        case .developer: "hammer"
        case .essentials: "house"
        case .custom: "slider.horizontal.3"
        }
    }
    var detail: String {
        switch self {
        case .agentic: "Follow sessions, monitor usage and review your agents' work."
        case .creative: "Create and edit media, record your screen and shape your workspace."
        case .developer: "Work with terminals, machines, databases and local documents."
        case .essentials: "Everyday tools for your clipboard, calendar and Mac."
        case .custom: "Choose exactly the tools you want."
        }
    }
    var suggestions: Set<String> {
        switch self {
        case .agentic: ["usage", "herdr", "quinjet", "companion", "plugins"]
        case .creative: ["studio", "timeLapse", "music", "colorPicker", "downloads"]
        case .developer: ["terminal", "machines", "docs", "database", "codeStats"]
        case .essentials: ["clipboard", "calendar", "system", "keepAwake", "emoji"]
        case .custom: []
        }
    }
}

struct HostWorkflowCost: Equatable, Sendable {
    let downloadBytes: Int64
    let installedBytes: Int64
    let packageIDs: Set<String>
    let unknownIDs: Set<String>
    var complete: Bool { unknownIDs.isEmpty }

    static func calculate(
        selected: Set<String>, available: [String: ExtensionPackage], installed: Set<String>
    ) -> Self {
        var pending = Array(selected), visited = Set<String>(), unknown = Set<String>()
        var download: Int64 = 0, storage: Int64 = 0
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, !installed.contains(id) else { continue }
            guard let package = available[id], package.downloadBytes > 0, package.installedBytes > 0
            else {
                unknown.insert(id)
                continue
            }
            let nextDownload = download.addingReportingOverflow(package.downloadBytes)
            let nextStorage = storage.addingReportingOverflow(package.installedBytes)
            guard !nextDownload.overflow, !nextStorage.overflow else {
                unknown.insert(id)
                continue
            }
            download = nextDownload.partialValue
            storage = nextStorage.partialValue
            pending.append(contentsOf: package.dependencies)
        }
        return Self(
            downloadBytes: download, installedBytes: storage,
            packageIDs: visited.subtracting(installed), unknownIDs: unknown)
    }
}
