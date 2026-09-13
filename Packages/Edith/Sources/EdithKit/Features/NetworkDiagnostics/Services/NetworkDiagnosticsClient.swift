import Foundation

public struct NetworkDiagnosticRequest: Codable, Sendable {
    public let id: UUID
    public var configuration: NetworkDiagnosticsConfiguration
    public var keepHistory: Bool
    public var saveBaseline: Bool

    public init(
        configuration: NetworkDiagnosticsConfiguration, keepHistory: Bool, saveBaseline: Bool
    ) {
        self.id = UUID()
        self.configuration = configuration
        self.keepHistory = keepHistory
        self.saveBaseline = saveBaseline
    }
}

public enum NetworkDiagnosticsClient {
    public static let cancelOperation = "network.cancel"
    public static let timelineOperation = "network.timeline"
    public static let saveBaselineOperation = "network.baseline.save"

    public static func diagnose(
        configuration: NetworkDiagnosticsConfiguration, keepHistory: Bool = true,
        saveBaseline: Bool = false, client: AgentClient = .shared
    ) async throws -> NetworkDiagnosticSnapshot {
        let request = NetworkDiagnosticRequest(
            configuration: configuration, keepHistory: keepHistory, saveBaseline: saveBaseline)
        return try await withTaskCancellationHandler {
            try await client.performAsync(
                NetworkDiagnosticSnapshot.self,
                operation: NetworkDiagnosticOperation.diagnose.descriptor.id,
                payload: AgentPayload.encode(request), timeout: 180)
        } onCancel: {
            Task {
                _ = try? await client.performInternalAsync(
                    cancelOperation, payload: AgentPayload.encode(request.id))
            }
        }
    }

    public static func timeline(limit: Int = 100) async throws -> [NetworkDiagnosticSnapshot] {
        try AgentPayload.decode(
            [NetworkDiagnosticSnapshot].self,
            from: await AgentClient.shared.performInternalAsync(
                timelineOperation, payload: AgentPayload.encode(limit)))
    }

    public static func saveBaseline(_ snapshot: NetworkDiagnosticSnapshot) async throws {
        _ = try await AgentClient.shared.performInternalAsync(
            saveBaselineOperation, payload: AgentPayload.encode(snapshot))
    }
}
