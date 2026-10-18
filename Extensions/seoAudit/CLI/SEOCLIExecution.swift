import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum SEOCLIEnvironment {
    @TaskLocal static var service: SEOAuditService?
}
struct SEOCLILaunch {
    struct Snapshot { let id: UUID; let state: SEOAuditJobState }
    let request: SEOAuditTaskRequest
    let snapshot: Snapshot?
    let project: SEOAuditProject?
}
@MainActor struct SEOCLIController {
    private var service: SEOAuditService {
        get throws {
            guard let service = SEOCLIEnvironment.service, !service.isStopped else {
                throw ExtensionPeerError.unavailable
            }
            return service
        }
    }
    func list() async throws -> [SEOAuditProjectSummary] { try await service.list() }
    func show(_ id: UUID) async throws -> SEOAuditProject { try await service.project(id) }
    func create(url: String, name: String?) async throws -> SEOAuditProject {
        try await service.create(url: url, name: name)
    }
    func rename(_ id: UUID, name: String) async throws -> SEOAuditProject {
        try await service.rename(id, name: name)
    }
    func delete(_ id: UUID) async throws { try await service.delete(id) }
    func draft(_ id: UUID) async throws -> SEOAuditDraft { try await service.draft(id) }
    func choose(_ id: UUID, edit: SEOAuditPageEdit) async throws -> SEOAuditDraft {
        try await service.choose(id, edit: edit)
    }
    func setLighthouse(_ id: UUID, enabled: Bool) async throws -> SEOAuditDraft {
        try await service.setLighthouse(id, enabled: enabled)
    }
    func discover(_ id: UUID) async throws -> SEOAuditDraft {
        let job = try await service.discover(id)
        guard case .draft(let draft) = try await job.value(cancellingOnCancel: true) else {
            throw ExtensionPeerError.invalidRequest
        }
        return draft
    }
    func start(_ id: UUID, lighthouse: Bool?, wait: Bool) async throws -> SEOCLILaunch {
        let launch = try await service.start(id, lighthouse: lighthouse)
        if wait {
            guard case .project(let project) = try await launch.job.value(cancellingOnCancel: true)
            else { throw ExtensionPeerError.invalidRequest }
            return .init(request: launch.request, snapshot: nil, project: project)
        }
        return .init(
            request: launch.request, snapshot: .init(id: launch.job.id, state: launch.state),
            project: nil)
    }
    func stop(_ id: UUID) async throws -> [UUID] { try await service.stop(id) }
    func run(_ id: UUID, runID: UUID?, offset: Int) async throws -> SEOAuditRun {
        try await service.run(id, runID: runID, offset: offset)
    }
}
@MainActor enum SEOCLIExecution {
    static func run(_ request: ExtensionCLIRequest, service: SEOAuditService) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        return try await SEOCLIEnvironment.$service.withValue(service) {
            try await ExtensionCLIExecution.run(SEOCommand.self, request: request)
        }
    }
    static func stream(
        _ streams: ExtensionCLIStreams, operation: String, payload: Data, service: SEOAuditService
    ) throws -> Data {
        try SEOCLIEnvironment.$service.withValue(service) {
            try streams.invoke(
                SEOCommand.self, operation: operation, prefix: "seoAudit.cli", payload: payload)
        }
    }
}
