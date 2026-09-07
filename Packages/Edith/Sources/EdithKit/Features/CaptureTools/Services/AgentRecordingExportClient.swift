import Foundation

public struct RecordingExportRequest: Codable, Sendable {
    public let take: ScreenRecordingTake
    public let document: ScreenRecordingEditDocument
    public let destination: URL
}

public enum AgentRecordingExportClient {
    public static func export(
        take: ScreenRecordingTake, document: ScreenRecordingEditDocument, to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let request = RecordingExportRequest(
            take: take, document: document, destination: destination)
        let submission = AgentTaskSubmission(
            operation: ScreenRecordingOperation.export.descriptor.id.rawValue,
            title: "Export recording", payload: try AgentPayload.encode(request))
        _ = try await AgentTaskClient().run(submission) { output in
            if let value = Double(output.text) { progress(value) }
        }
    }
}
