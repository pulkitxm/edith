import Foundation

public struct HostFolderChoiceResult: Sendable, Equatable {
    public let selectedPath: String?
    public let cancelled: Bool?

    public init(selectedPath: String? = nil, cancelled: Bool? = nil) {
        self.selectedPath = selectedPath
        self.cancelled = cancelled
    }

    public func validate() throws {
        if let selectedPath {
            guard cancelled == nil, selectedPath.hasPrefix("/"), selectedPath.utf8.count <= 4096,
                !selectedPath.utf8.contains(0),
                selectedPath.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." })
            else { throw HostWorkerError.invalidResponse }
        } else {
            guard cancelled == true else { throw HostWorkerError.invalidResponse }
        }
    }

    public var dictionary: NSDictionary {
        if let selectedPath { return ["selectedPath": selectedPath] }
        return ["cancelled": true]
    }
}
