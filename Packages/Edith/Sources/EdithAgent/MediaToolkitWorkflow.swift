import EdithKit
import Foundation

public enum MediaToolkitWorkflow {
    public static func register(on tasks: AgentTaskService) async {
        await tasks.register(
            operation: MediaToolkitOperation.convertImages.descriptor.id.rawValue, concurrency: 1
        ) { payload, context in
            try requireEnabled()
            let request = try AgentPayload.decode(MediaImageTaskRequest.self, from: payload)
            let result = try MediaToolkit.convertImages(
                request.inputs, to: request.destination, options: request.options,
                progress: { completed, _ in context.report(String(completed)) },
                cancelled: { Task.isCancelled })
            return try AgentPayload.encode(result)
        }
        await tasks.register(
            operation: MediaToolkitOperation.compressVideo.descriptor.id.rawValue, concurrency: 1
        ) { payload, context in
            try requireEnabled()
            let request = try AgentPayload.decode(MediaVideoTaskRequest.self, from: payload)
            let result = try await MediaToolkit.compressVideo(
                request.input, to: request.destination, options: request.options,
                progress: { context.report(String($0)) }, cancelled: { Task.isCancelled })
            return try AgentPayload.encode(result)
        }
    }

    private static func requireEnabled() throws {
        guard ExtensionRegistry.entry("mediaToolkit")?.isEnabled(in: SharedDefaults.store) == true else {
            throw MediaToolkitError.failed("Enable the Media Toolkit ability before processing media.")
        }
    }
}
