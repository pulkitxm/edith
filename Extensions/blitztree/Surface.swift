import EdithExtensionSupport
import Foundation

@MainActor
enum BlitzTreeSurface {
    static func snapshot(_ model: BlitzTreeModel) -> SurfaceSnapshot {
        let report = model.report
        var metrics: [SurfaceMetric] = []
        if let report {
            let reclaimable = reclaimableBytes(report.report.candidates)
            metrics = [
                .init(
                    "space", "Cleanup candidates",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: reclaimable), countStyle: .file)),
                .init("categories", "Candidates", report.report.candidateCount.description),
            ]
        }
        var actions: [SurfaceAction] = []
        if !model.removing {
            if model.scanning {
                actions = [.init("cancel", "Cancel scan", "xmark.circle")]
            } else {
                actions = [.init("choose", "Choose folder", "folder")];
                if model.root != nil {
                    actions.append(.init("rescan", "Rescan", "arrow.clockwise"))
                }
            }
        }
        return .init(
            providerID: "blitztree", metrics: metrics,
            rows: report?.report.inventory.largestChildren.prefix(100).enumerated().map {
                index, entry in
                .init(
                    "entry:" + index.description, title: String(entry.name.prefix(1024)),
                    detail: entry.isDirectory ? "Folder" : "File",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: entry.allocatedBytes), countStyle: .file),
                    icon: entry.isDirectory ? "folder" : "doc")
            } ?? [], actions: actions,
            message: model.error
                ?? (model.scanning
                    ? "Scanned " + model.scannedEntries.description + " entries"
                    : report == nil ? "Choose a folder to inspect its storage." : nil))
    }

    static func reclaimableBytes(_ entries: [BlitzTreeReport.Entry]) -> UInt64 {
        var roots: [String] = []
        var identities = Set<String>()
        var total: UInt64 = 0
        for entry in entries.sorted(by: { $0.path.count < $1.path.count }) {
            guard !roots.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }),
                identities.insert(entry.device.description + ":" + entry.inode.description).inserted
            else { continue }
            roots.append(entry.path)
            let next = total.addingReportingOverflow(entry.allocatedBytes)
            total = next.overflow ? UInt64.max : next.partialValue
        }
        return total
    }
}
