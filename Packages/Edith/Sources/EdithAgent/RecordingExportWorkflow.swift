import EdithKit
import Foundation

public enum RecordingExportWorkflow {
    public static func register(on tasks: AgentTaskService) async {
        await tasks.register(
            operation: ScreenRecordingOperation.export.descriptor.id.rawValue, concurrency: 1
        ) { payload, context in
            guard
                ExtensionRegistry.entry("captureTools")?.isEnabled(in: SharedDefaults.store) == true
            else {
                throw NSError(
                    domain: "RecordingExport", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Enable Capture Tools in the Media suite before exporting recordings."
                    ])
            }
            let request = try AgentPayload.decode(RecordingExportRequest.self, from: payload)
            let exporter = ScreenRecordingExporter()
            exporter.onProgress = { context.report(String($0)) }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await exporter.export(
                    take: request.take, document: request.document, to: request.destination)
            } onCancel: {
                exporter.cancel()
            }
            return try AgentPayload.encode(request.destination)
        }
    }
}
