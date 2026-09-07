import Foundation

public enum AgentAutomationOperation {
    public static let load = "automations.document.load"
    public static let save = "automations.document.save"
    public static let history = "automations.history.load"
    public static let run = "automations.scene.execute"
    public static let internalOperations = [load, save, history]
}

public struct AgentAutomationRunRequest: Codable, Sendable {
    public let sceneID: UUID
    public let origin: AutomationRunOrigin
    public let automationID: UUID?
    public let grantedPermissions: Set<AutomationPermission>

    public init(
        sceneID: UUID, origin: AutomationRunOrigin, automationID: UUID? = nil,
        grantedPermissions: Set<AutomationPermission> = []
    ) {
        self.sceneID = sceneID
        self.origin = origin
        self.automationID = automationID
        self.grantedPermissions = grantedPermissions
    }
}

public enum AgentAutomationClient {
    public static func run(_ request: AgentAutomationRunRequest) async throws -> AutomationRunRecord
    {
        let submission = AgentTaskSubmission(
            operation: AgentAutomationOperation.run,
            title: "Run automation scene", payload: try AgentPayload.encode(request))
        return try AgentPayload.decode(
            AutomationRunRecord.self, from: await AgentTaskClient().run(submission))
    }
}
