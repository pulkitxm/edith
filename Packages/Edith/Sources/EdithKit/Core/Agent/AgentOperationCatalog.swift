import EdithCore
import Foundation

public enum AgentOperationCatalog {
    private static let usageOperations: [UserOperationID] = [
        UsageCollectionOperation.refresh.descriptor.id,
        UsageCollectionOperation.limitsRefresh.descriptor.id,
    ]

    public static let served: [UserOperationID] =
        AgentControlOperation.allCases.map { $0.descriptor.id } + usageOperations

    public static let internalOperations: [String] =
        [
            AttentionOperation.record, AttentionOperation.range, AttentionOperation.importLegacy,
            AgentBus.publish, AgentBus.subscribe, AgentBus.unsubscribe,
            AgentDiagnostics.runJob, AgentDiagnostics.cancelJob,
            AgentNotificationOperation.pending, AgentNotificationOperation.acknowledge,
            CompanionBackgroundOperation.refresh, AgentMachineMetricsRefresh.operation,
        ] + AgentTaskOperation.internalOperations + AgentDownloadOperation.internalOperations

    public static func serves(_ id: UserOperationID) -> Bool {
        served.contains(id)
    }

    public static func servesInternal(_ name: String) -> Bool {
        internalOperations.contains(name)
    }

    public static var allNames: [String] {
        served.map(\.rawValue) + internalOperations
    }

    public static var descriptors: [UserOperationDescriptor] {
        served.compactMap { UserOperationCatalog.descriptor(id: $0) }
    }
}
