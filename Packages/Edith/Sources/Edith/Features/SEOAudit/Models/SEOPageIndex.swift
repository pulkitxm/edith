import EdithKit
import Foundation

struct SEOPageFilterEntry: Sendable {
    var id: UUID
    var url: String
    var title: String
    var severities: Set<SEOAuditSeverity>
}

struct SEOPageIndexSnapshot: Sendable {
    var entries: [SEOPageFilterEntry] = []
    var pages: [UUID: SEOAuditPageResult] = [:]
    var ordered: [SEOAuditPageResult] = []
    var history: [String: [SEOAuditPageResult]] = [:]

    static let empty = SEOPageIndexSnapshot()
}

enum SEOPageIndex {
    static var recordThread: (@Sendable () -> Void)?

    static func build(project: SEOAuditProject?, runID: UUID?) -> SEOPageIndexSnapshot {
        recordThread?()
        guard let project else { return .empty }
        let run =
            runID.flatMap { id in project.runs.first { $0.id == id } } ?? project.latestRun
        guard let run else { return .empty }
        var snapshot = SEOPageIndexSnapshot()
        snapshot.ordered = run.pages
        snapshot.pages = Dictionary(uniqueKeysWithValues: run.pages.map { ($0.id, $0) })
        snapshot.entries = run.pages.map { page in
            SEOPageFilterEntry(
                id: page.id, url: page.url, title: page.metadata.title ?? "",
                severities: Set(page.issues.map(\.severity)))
        }
        var history: [String: [SEOAuditPageResult]] = [:]
        for previous in project.runs where previous.id != run.id {
            for page in previous.pages {
                history[page.url, default: []].append(page)
            }
        }
        for (url, pages) in history {
            history[url] = pages.sorted { $0.auditedAt > $1.auditedAt }
        }
        snapshot.history = history
        return snapshot
    }

    static func matchingIDs(
        _ entries: [SEOPageFilterEntry], query: String, severity: SEOAuditSeverity?
    ) -> [UUID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids: [UUID] = []
        ids.reserveCapacity(entries.count)
        for entry in entries {
            if !trimmed.isEmpty,
                !entry.url.localizedCaseInsensitiveContains(trimmed),
                !entry.title.localizedCaseInsensitiveContains(trimmed)
            {
                continue
            }
            if let severity, !entry.severities.contains(severity) { continue }
            ids.append(entry.id)
        }
        return ids
    }
}
