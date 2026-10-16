import Foundation
import Testing
@testable import SEOAuditExtension

@MainActor @Suite struct SEOAuditServiceTests {
    @Test func ownedQueueCancelsWaitingAndActiveJobsAndDrainsOnShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SEOAuditServiceProtocol.self]
        let network = SEOAuditHTTPClient(configuration: configuration)
        let workflow = SEOAuditWorkflow(
            repository: SEOAuditRepository(root: root), network: network,
            lighthouse: LighthouseAuditor(locate: { nil }))
        let service = SEOAuditService(workflow: workflow)
        let first = try await service.create(
            url: "https://synthetic.example.invalid/first", name: "First")
        let second = try await service.create(
            url: "https://synthetic.example.invalid/second", name: "Second")
        for project in [first, second] {
            _ = try await service.setDraft(
                project.id,
                .init(
                    discoveredPageURLs: [project.baseURL], selectedPageURLs: [project.baseURL],
                    includeLighthouse: false))
        }
        let one = try await service.start(first.id, lighthouse: false)
        let two = try await service.start(second.id, lighthouse: false)
        for _ in 0..<100 {
            if service.activity(for: first.id)?.state == .running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.activity(for: first.id)?.state == .running)
        #expect(service.activity(for: second.id)?.state == .queued)
        #expect(service.cancel(two.job.id))
        _ = try? await two.job.value(cancellingOnCancel: false)
        await service.shutdown()
        _ = try? await one.job.value(cancellingOnCancel: false)
        #expect(service.jobCount == 0)
        #expect(service.activities.isEmpty && service.listenerCount == 0)
        #expect(service.isStopped)
        await #expect(throws: SEOAuditInputError.self) { _ = try await service.list() }
        let retained = try SEOAuditRepository(root: root).loadProject(id: first.id)
        #expect(retained.latestRun?.state == .cancelled)
    }

    @Test func selectionMutationsStayInsideTheCurrentProjectDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SEOAuditService(
            workflow: SEOAuditWorkflow(
                repository: SEOAuditRepository(root: root),
                lighthouse: LighthouseAuditor(locate: { nil })))
        let project = try await service.create(
            url: "https://synthetic.example.invalid", name: "Synthetic")
        let url = project.baseURL + "/known"
        _ = try await service.setDraft(
            project.id,
            .init(discoveredPageURLs: [url], selectedPageURLs: [url], includeLighthouse: false))
        await #expect(throws: SEOAuditInputError.self) {
            _ = try await service.choose(project.id, edit: .add(["https://other.invalid/private"]))
        }
        #expect(try await service.draft(project.id).selectedPageURLs == [url])
        _ = try await service.choose(project.id, edit: .none)
        #expect(try await service.draft(project.id).selectedPageURLs.isEmpty)
        await service.shutdown()
    }
}

private final class SEOAuditServiceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
