import EdithKit
import Foundation

public enum AgentScratchpadOperations {
    public static func register(on runtime: AgentRuntime) async {
        for operation in AgentScratchpadClient.operations {
            await runtime.register(operation: operation.descriptor.id.rawValue) { payload in
                let request = try AgentPayload.decode(ScratchpadRequest.self, from: payload)
                let document: ScratchpadDocument
                switch operation {
                case .list:
                    document = try ScratchpadRepository.load(retention: request.retention, now: request.now)
                case .create:
                    document = try ScratchpadRepository.create(name: request.name, text: request.text, now: request.now)
                case .update:
                    document = try ScratchpadRepository.update(request.selector, text: request.text, now: request.now)
                case .rename:
                    document = try ScratchpadRepository.rename(request.selector, to: request.name ?? "")
                case .duplicate:
                    document = try ScratchpadRepository.duplicate(request.selector, now: request.now)
                case .remove:
                    document = try ScratchpadRepository.remove(request.selector)
                case .clear:
                    document = try ScratchpadRepository.clear(request.selector, now: request.now)
                default:
                    throw ScratchpadError.invalidName
                }
                if operation != .list { IPC.post(IPC.Name.scratchpadChanged) }
                return try AgentPayload.encode(document)
            }
        }
        await runtime.register(operation: AgentScratchpadClient.selectOperation) { payload in
            let request = try AgentPayload.decode(ScratchpadRequest.self, from: payload)
            return try AgentPayload.encode(ScratchpadRepository.select(request.selector))
        }
    }
}
