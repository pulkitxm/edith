import EdithKit
import Foundation

public enum AgentOperations {
    public static func register(
        on runtime: AgentRuntime, store: AgentStore? = nil, scheduler: JobScheduler? = nil,
        downloads: DownloadWorker? = nil
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
        if let downloads {
            await runtime.registerShutdown(id: "downloads") { await downloads.stop() }
            await runtime.register(operation: AgentDownloadOperation.snapshot) { _ in
                try await AgentPayload.encode(downloads.snapshot())
            }
            await runtime.register(operation: AgentDownloadOperation.mutate) { payload in
                let request = try AgentPayload.decode(AgentDownloadMutation.self, from: payload)
                return try await AgentPayload.encode(downloads.mutate(request))
            }
        }
        await registerControls(on: runtime)
        await AgentNotificationOperations.register(on: runtime)
        if let scheduler {
            await registerUsage(on: runtime, scheduler: scheduler)
            await runtime.register(operation: CompanionBackgroundOperation.refresh) { _ in
                guard await scheduler.enqueue("companion.health") else {
                    throw AgentError(.refused, "Memory is disabled.")
                }
                return Data()
            }
            await runtime.register(operation: AgentDiagnostics.runJob) { payload in
                let id = try AgentPayload.decode(String.self, from: payload)
                guard await scheduler.enqueue(id) else {
                    throw AgentError(.refused, "This job is disabled or is not registered.")
                }
                return Data()
            }
            await runtime.register(operation: AgentDiagnostics.cancelJob) { payload in
                let id = try AgentPayload.decode(String.self, from: payload)
                await scheduler.cancel(id)
                return Data()
            }
        }
    }

    static func registerUsage(on runtime: AgentRuntime, scheduler: JobScheduler) async {
        await runtime.register(
            operation: UsageCollectionOperation.refresh.descriptor.id.rawValue
        ) { _ in
            guard await scheduler.enqueue("usage.refresh") else {
                throw AgentError(.refused, "Usage collection is disabled.")
            }
            return Data()
        }
        await runtime.register(
            operation: UsageCollectionOperation.limitsRefresh.descriptor.id.rawValue
        ) { _ in
            guard await scheduler.enqueue("usage.limits") else {
                throw AgentError(.refused, "Usage collection is disabled.")
            }
            return Data()
        }
    }

    static func registerControls(on runtime: AgentRuntime) async {
        await runtime.register(operation: AgentControlOperation.events.descriptor.id.rawValue) {
            _ in
            try await runtime.snapshot(topic: .events)
        }
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
                raise(SIGTERM)
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
