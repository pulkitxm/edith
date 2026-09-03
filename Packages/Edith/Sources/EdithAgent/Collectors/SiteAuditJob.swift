import EdithKit
import Foundation

public final class SiteAuditJob: @unchecked Sendable {
    private let store: AgentStore?
    private let auditor: SEOPageAuditor
    private let lighthouse: LighthouseAuditor
    private let lock = NSLock()
    private var pending: SiteAuditRequest?

    public init(
        store: AgentStore?, auditor: SEOPageAuditor = SEOPageAuditor(),
        lighthouse: LighthouseAuditor = LighthouseAuditor()
    ) {
        self.store = store
        self.auditor = auditor
        self.lighthouse = lighthouse
    }

    public func enqueue(_ request: SiteAuditRequest) {
        lock.lock()
        pending = request
        lock.unlock()
    }

    private func take() -> SiteAuditRequest? {
        lock.lock()
        defer { lock.unlock() }
        let request = pending
        pending = nil
        return request
    }

    public func run() async throws -> Data? {
        guard let request = take(), !request.urls.isEmpty else { return nil }
        let startedAt = Date()
        let auditor = auditor
        let lighthouse = lighthouse
        let wantsLighthouse = request.lighthouse
        let pages = await BoundedTaskRunner.map(
            request.urls, limit: SiteAuditConcurrency.limit
        ) { _, url in
            var page = await auditor.audit(url)
            if wantsLighthouse {
                let result = await lighthouse.audit(url)
                page = page.with(scores: result.scores, lighthouseError: result.error)
            }
            return page
        }
        return try AgentPayload.encode(
            SiteAuditSnapshot(
                startedAt: startedAt, requested: request.urls.count, audited: pages.count,
                concurrency: SiteAuditConcurrency.slots(for: request.urls.count),
                failure: nil))
    }
}
