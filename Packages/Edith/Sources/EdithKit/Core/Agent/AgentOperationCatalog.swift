import EdithCore
import Foundation

public enum AgentOperationCatalog {
    public static let served: [UserOperationID] = AgentControlOperation.allCases.map {
        $0.descriptor.id
    }

    public static func serves(_ id: UserOperationID) -> Bool {
        served.contains(id)
    }

    public static var descriptors: [UserOperationDescriptor] {
        served.compactMap { UserOperationCatalog.descriptor(id: $0) }
    }
}
