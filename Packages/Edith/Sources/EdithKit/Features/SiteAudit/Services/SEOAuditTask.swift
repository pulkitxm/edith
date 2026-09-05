import Foundation

public enum SEOAuditTaskOperation {
    public static let discover = "site.discover"
    public static let audit = "site.audit"
    public static let lighthouse = "site.lighthouse"
    public static let projects = "site.projects"
    public static let project = "site.project"
    public static let create = "site.create"
    public static let rename = "site.rename"
    public static let delete = "site.delete"
    public static let internalOperations = [projects, project, create, rename, delete]
}

public struct SEOAuditTaskRequest: Codable, Sendable {
    public let projectID: UUID
    public let runID: UUID
    public let urls: [URL]
    public let lighthouse: Bool

    public init(projectID: UUID, runID: UUID, urls: [URL], lighthouse: Bool) {
        self.projectID = projectID
        self.runID = runID
        self.urls = urls
        self.lighthouse = lighthouse
    }
}

public struct SEOAuditRenameRequest: Codable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SEOAuditProjectClient: Sendable {
    public typealias Perform = @Sendable (String, Data) async throws -> Data
    private let perform: Perform

    public init(
        perform: @escaping Perform = {
            try await AgentClient.shared.performInternalAsync($0, payload: $1)
        }
    ) {
        self.perform = perform
    }

    public func projects() async throws -> [SEOAuditProjectSummary] {
        try await request([SEOAuditProjectSummary].self, SEOAuditTaskOperation.projects, Data())
    }

    public func project(_ id: UUID) async throws -> SEOAuditProject {
        try await request(
            SEOAuditProject.self, SEOAuditTaskOperation.project, AgentPayload.encode(id))
    }

    public func create(_ project: SEOAuditProject) async throws -> SEOAuditProject {
        try await request(
            SEOAuditProject.self, SEOAuditTaskOperation.create, AgentPayload.encode(project))
    }

    public func rename(_ id: UUID, name: String) async throws -> SEOAuditProject {
        try await request(
            SEOAuditProject.self, SEOAuditTaskOperation.rename,
            AgentPayload.encode(SEOAuditRenameRequest(id: id, name: name)))
    }

    public func delete(_ id: UUID) async throws {
        _ = try await perform(SEOAuditTaskOperation.delete, AgentPayload.encode(id))
    }

    private func request<T: Decodable>(_ type: T.Type, _ operation: String, _ payload: Data)
        async throws -> T
    {
        try AgentPayload.decode(type, from: await perform(operation, payload))
    }
}
