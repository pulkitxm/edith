import Foundation

public struct MediaImageTaskRequest: Codable, Sendable {
    public let inputs: [URL]
    public let destination: URL
    public let options: MediaImageOptions
}

public struct MediaVideoTaskRequest: Codable, Sendable {
    public let input: URL
    public let destination: URL
    public let options: MediaVideoOptions
}

public enum AgentMediaClient {
    public static func convertImages(
        _ inputs: [URL], to destination: URL, options: MediaImageOptions,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [MediaImageResult] {
        let request = MediaImageTaskRequest(inputs: inputs, destination: destination, options: options)
        let submission = AgentTaskSubmission(
            operation: MediaToolkitOperation.convertImages.descriptor.id.rawValue,
            title: "Convert images", payload: try AgentPayload.encode(request))
        let data = try await AgentTaskClient().run(submission) { output in
            guard let completed = Int(output.text) else { return }
            progress(completed, inputs.count)
        }
        return try AgentPayload.decode([MediaImageResult].self, from: data)
    }

    public static func compressVideo(
        _ input: URL, to destination: URL, options: MediaVideoOptions,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> MediaVideoResult {
        let request = MediaVideoTaskRequest(input: input, destination: destination, options: options)
        let submission = AgentTaskSubmission(
            operation: MediaToolkitOperation.compressVideo.descriptor.id.rawValue,
            title: "Compress video", payload: try AgentPayload.encode(request))
        let data = try await AgentTaskClient().run(submission) { output in
            guard let value = Double(output.text) else { return }
            progress(value)
        }
        return try AgentPayload.decode(MediaVideoResult.self, from: data)
    }
}
