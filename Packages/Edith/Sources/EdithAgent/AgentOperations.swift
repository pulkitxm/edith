import EdithKit
import Foundation

public enum AgentOperations {
    public static func register(on runtime: AgentRuntime, store: AgentStore? = nil) async {
        if let store {
            let attention = AttentionEventStore(store: store)
            await runtime.register(operation: AttentionOperation.record) { payload in
                let batch = try AgentPayload.decode(AttentionBatch.self, from: payload)
                try attention.record(batch)
                return try AgentPayload.encode(["recorded": batch.events.count])
            }
            await runtime.register(operation: AttentionOperation.range) { payload in
                let request = try AgentPayload.decode(
                    AttentionRangeRequest.self, from: payload)
                let events = try attention.events(from: request.from, to: request.to)
                return try AgentPayload.encode(AttentionRangeResponse(events: events))
            }
            await runtime.register(operation: AttentionOperation.importLegacy) { _ in
                try AgentPayload.encode(try attention.importLegacyFiles())
            }
        }
        await registerControls(on: runtime)
    }

    static func registerControls(on runtime: AgentRuntime) async {
        await runtime.register(operation: AgentControlOperation.status.descriptor.id.rawValue) {
            _ in
            try AgentPayload.encode(await runtime.runtimeSnapshot())
        }
        await runtime.register(operation: AgentControlOperation.jobs.descriptor.id.rawValue) {
            _ in
            try AgentPayload.encode(await runtime.jobSnapshots())
        }
        await runtime.register(operation: AgentControlOperation.logs.descriptor.id.rawValue) {
            payload in
            let window = String(data: payload, encoding: .utf8) ?? "1h"
            let lines = await Task.detached(priority: .userInitiated) {
                AgentLogQuery.recent(last: window)
            }.value
            return try AgentPayload.encode(lines)
        }
        await runtime.register(operation: AgentControlOperation.restart.descriptor.id.rawValue) {
            _ in
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                AgentLog.logger.info("restart requested")
                exit(0)
            }
            return try AgentPayload.encode(["restarted": true])
        }
    }
}

public enum AgentLogQuery {
    public static let windowPattern = "^[0-9]+[smhd]$"

    public static func isValidWindow(_ window: String) -> Bool {
        window.range(of: windowPattern, options: .regularExpression) != nil
    }

    public static func recent(last: String) -> [String] {
        let window = isValidWindow(last) ? last : "1h"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--style", "compact", "--last", window, "--predicate",
            "subsystem == \"\(AgentLog.subsystem)\"",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
    }
}
