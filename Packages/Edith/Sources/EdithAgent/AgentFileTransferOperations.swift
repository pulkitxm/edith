import EdithKit
import Foundation

public enum AgentFileTransferOperations {
    public static func register(on tasks: AgentTaskService) async {
        await tasks.register(operation: AgentFileTransferRequest.operation) { payload, context in
            let request = try AgentPayload.decode(AgentFileTransferRequest.self, from: payload)
            guard request.plan.items.count <= 10_000 else {
                throw AgentError(.refused, "A transfer can contain at most 10,000 files.")
            }
            for item in request.plan.items {
                try validate(item.sourcePath, location: request.source)
                try validate(item.destinationPath, location: request.destination)
                if request.source == request.destination,
                    sameItem(item.sourcePath, item.destinationPath, location: request.source)
                {
                    throw AgentError(.refused, "A file cannot be transferred onto itself.")
                }
            }
            let source = try await endpoint(for: request.source)
            let destination = try await endpoint(for: request.destination)
            let outcome = try await RemoteTransferOperationExecution.execute(
                request.plan, from: source, to: destination,
                confirmsReplacement: request.confirmsReplacement, moving: request.moving
            ) { processed, total in
                context.report("files:\(processed):\(total)")
            }
            let data = try AgentPayload.encode(outcome)
            guard outcome.failures.isEmpty else {
                throw AgentTaskExecutionError(
                    code: "filesIncomplete",
                    message: "\(outcome.failures.count) files could not be transferred.",
                    result: data)
            }
            return data
        }
    }

    private static func sameItem(
        _ source: String, _ destination: String, location: AgentFileTransferLocation
    ) -> Bool {
        guard case .local = location else {
            return (source as NSString).standardizingPath
                == (destination as NSString).standardizingPath
        }
        let sourceURL = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
            .resolvingSymlinksInPath()
        if sourceURL.path == destinationURL.path { return true }
        guard let sourceInfo = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
            let destinationInfo = try? FileManager.default.attributesOfItem(
                atPath: destinationURL.path),
            let sourceDevice = sourceInfo[.systemNumber] as? NSNumber,
            let destinationDevice = destinationInfo[.systemNumber] as? NSNumber,
            let sourceInode = sourceInfo[.systemFileNumber] as? NSNumber,
            let destinationInode = destinationInfo[.systemFileNumber] as? NSNumber
        else { return false }
        return sourceDevice == destinationDevice && sourceInode == destinationInode
    }

    private static func validate(_ path: String, location: AgentFileTransferLocation) throws {
        guard !path.isEmpty, !path.contains("\0") else {
            throw AgentError(.refused, "The transfer path is invalid.")
        }
        if case .local = location, !path.hasPrefix("/") {
            throw AgentError(.refused, "Local transfer paths must be absolute.")
        }
    }

    private static func endpoint(for location: AgentFileTransferLocation) async throws
        -> RemoteTransferEndpoint
    {
        try Task.checkCancellation()
        switch location {
        case .local: return .local(machineID: Machine.localID, name: "This Mac")
        case let .remote(machine):
            let connection = try await AgentMachineConnectionPool.shared.connection(for: machine)
            try Task.checkCancellation()
            return .remote(machine: machine, connection: connection)
        }
    }
}
