import EdithHostCore
import ExtensionMarketplace
import Foundation

enum HostWorkflow: String, CaseIterable, Identifiable, Sendable {
    case agents, utilities, desk, media, developer, custom
    var id: String { rawValue }
    var suite: HostMarketplaceSuite? { HostMarketplaceCatalog.suites.first { $0.id == rawValue } }
    var title: String { suite?.title ?? "Custom" }
    var symbol: String { suite?.symbol ?? "slider.horizontal.3" }
    var detail: String { suite?.subtitle ?? "Choose exactly the extensions you want." }
    func suggestions(in entries: [HostExtension]) -> Set<String> {
        Set(entries.filter { $0.category == rawValue }.map(\.id))
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
