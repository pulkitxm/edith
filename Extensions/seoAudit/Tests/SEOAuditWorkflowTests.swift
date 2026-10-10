import Foundation
import Network
import Testing
@testable import SEOAuditExtension

@Suite struct SEOAuditWorkflowTests {
    @Test func realHTTPAuditPersistsProgressAndProtectsTheActiveProject() async throws {
        let fixture = try await makeFixture()
        defer {
            fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.repository.root)
        }
        let oldRun = SEOAuditRun(startedAt: Date(timeIntervalSince1970: 100), state: .completed)
        let project = SEOAuditProject(
            name: "Fixture", baseURL: fixture.origin.absoluteString, runs: [oldRun])
        try fixture.repository.save(project)
        let workflow = SEOAuditWorkflow(repository: fixture.repository)
        let urls = [
            fixture.origin.appendingPathComponent("fast"),
            fixture.origin.appendingPathComponent("slow"),
        ]
        let runID = UUID()
        let request = SEOAuditTaskRequest(
            projectID: project.id, runID: runID, urls: urls, lighthouse: false)
        let task = Task { try await workflow.run(request) }
        try await eventually {
            try fixture.repository.loadProject(id: project.id).runs.first?.pages.count == 1
        }
        await #expect(throws: SEOAuditInputError.self) { try await workflow.delete(project.id) }
        _ = try await task.value
        let saved = try fixture.repository.loadProject(id: project.id)
        #expect(saved.runs[0].id == runID)
        #expect(saved.runs[0].state == .completed)
        #expect(saved.runs[0].pages.map(\.url) == urls.map(\.absoluteString))
        #expect(saved.runs[0].pages.allSatisfy { $0.metadata.title == "Fixture page" })
        #expect(saved.runs[1] == oldRun)
        await workflow.shutdown()
    }

    @Test func cancellationRetainsCompletedPagesInTheRequestedRun() async throws {
        let fixture = try await makeFixture()
        defer {
            fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.repository.root)
        }
        let project = SEOAuditProject(name: "Cancellation", baseURL: fixture.origin.absoluteString)
        try fixture.repository.save(project)
        let workflow = SEOAuditWorkflow(repository: fixture.repository)
        let request = SEOAuditTaskRequest(
            projectID: project.id, runID: UUID(),
            urls: [
                fixture.origin.appendingPathComponent("fast"),
                fixture.origin.appendingPathComponent("slow"),
            ], lighthouse: false)
        let task = Task { try await workflow.run(request) }
        try await eventually {
            try fixture.repository.loadProject(id: project.id).runs.first?.pages.count == 1
        }
        task.cancel(); _ = try? await task.value
        let saved = try fixture.repository.loadProject(id: project.id)
        #expect(saved.runs[0].state == .cancelled)
        #expect(saved.runs[0].pages.count == 1)
        #expect(saved.runs[0].finishedAt != nil)
        await workflow.shutdown()
    }

    @Test func restartMarksUnfinishedRunsAndLeavesCompletedHistoryIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root)
        let complete = SEOAuditRun(startedAt: Date(timeIntervalSince1970: 100), state: .completed)
        let project = SEOAuditProject(
            name: "Restart", baseURL: "https://example.com", runs: [SEOAuditRun(), complete])
        try repository.save(project)
        let workflow = SEOAuditWorkflow(repository: repository)
        try await workflow.recoverInterruptedRuns()
        let restored = try repository.loadProject(id: project.id)
        #expect(restored.runs[0].state == .failed)
        #expect(restored.runs[0].error?.contains("stopped") == true)
        #expect(restored.runs[1] == complete)
        await workflow.shutdown()
    }

    @Test func discoveryUsesRealRobotsAndSitemapResponses() async throws {
        let fixture = try await makeFixture()
        defer {
            fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.repository.root)
        }
        let workflow = SEOAuditWorkflow(repository: fixture.repository)
        let urls = try await workflow.discover(fixture.origin)
        #expect(urls == [fixture.origin.appendingPathComponent("fast")])
        await #expect(throws: SEOAuditInputError.self) {
            _ = try await workflow.discover(URL(fileURLWithPath: "/tmp"))
        }
        await workflow.shutdown()
    }

    private func makeFixture() async throws -> (
        server: SEOAuditHTTPFixture, origin: URL, repository: SEOAuditRepository
    ) {
        let server = try SEOAuditHTTPFixture()
        let origin = try await server.origin()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (server, origin, SEOAuditRepository(root: root))
    }
    private func eventually(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SEOAuditInputError("Fixture did not reach the expected state.")
    }
}

private final class SEOAuditHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "edith.site.fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var boundPort: UInt16?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port, port.rawValue > 0
            else { return }
            self.lock.withLock { self.boundPort = port.rawValue }
        }
        listener.start(queue: queue)
    }

    func origin() async throws -> URL {
        for _ in 0..<100 {
            if let port = lock.withLock({ boundPort }) {
                return URL(string: "http://127.0.0.1:\(port)/")!
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SEOAuditInputError("Fixture server did not start.")
    }

    func stop() {
        listener.cancel()
        let current = lock.withLock { connections }
        for connection in current { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, _, _ in
            guard let self, let data, let port = self.listener.port else { return }
            let request = String(decoding: data, as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let origin = "http://127.0.0.1:\(port.rawValue)"
            let body: String
            if path == "/robots.txt" {
                body = "Sitemap: \(origin)/sitemap.xml\n"
            } else if path == "/sitemap.xml" {
                body = "<urlset><url><loc>\(origin)/fast</loc></url></urlset>"
            } else {
                body =
                    "<html lang='en'><head><title>Fixture page</title></head><body><h1>Fixture</h1></body></html>"
            }
            let response =
                "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            self.queue.asyncAfter(deadline: .now() + (path == "/slow" ? 1.5 : 0)) {
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
