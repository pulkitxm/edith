import EdithKit
import Foundation

public enum AgentOperations {
    public static func register(
        on runtime: AgentRuntime, store: AgentStore? = nil, scheduler: JobScheduler? = nil
    ) async {
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
        if let scheduler {
            await registerUsage(on: runtime, scheduler: scheduler)
        }
    }

    static func registerUsage(on runtime: AgentRuntime, scheduler: JobScheduler) async {
        await runtime.register(
            operation: UsageCollectionOperation.refresh.descriptor.id.rawValue
        ) { _ in
            await scheduler.enqueue("usage.refresh")
            return Data()
        }
        await runtime.register(
            operation: UsageCollectionOperation.limitsRefresh.descriptor.id.rawValue
        ) { _ in
            await scheduler.enqueue("usage.limits")
            return Data()
        }
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
            return try AgentPayload.encode(await AgentLogQuery.recent(last: window))
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

    public static let timeout: TimeInterval = 20
    public static let maximumOutputBytes = 4 << 20

    public static func request(last: String) -> CLICommandRequest {
        let window = isValidWindow(last) ? last : "1h"
        return CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/log"),
            arguments: [
                "show", "--style", "compact", "--last", window, "--predicate",
                "subsystem == \"\(AgentLog.subsystem)\"",
            ],
            environment: CLIToolEnvironment.sanitized(), timeout: timeout,
            maximumOutputBytes: maximumOutputBytes, discardsStandardError: true,
            terminatesProcessGroup: true)
    }

    public static func recent(last: String) async -> [String] {
        guard let result = try? await CLICommandRunner.run(request(last: last), onLine: { _ in })
        else { return [] }
        return result.standardOutput.split(separator: "\n").map(String.init)
    }
}
