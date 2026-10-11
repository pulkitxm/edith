import Foundation

#if EDITH_FUNCTIONAL_FIXTURE
@MainActor public struct HostFixtureRoleAdmission {
    public enum Failure: Error { case rejected }
    public let roleDirectory: URL
    public let contextMarker: [String: String]
    private let revalidate: () throws -> Void

    public init(
        roleDirectory: URL, contextMarker: [String: String], revalidate: @escaping () throws -> Void
    ) {
        self.roleDirectory = roleDirectory
        self.contextMarker = contextMarker
        self.revalidate = revalidate
    }

    public func requireCurrent() throws { try revalidate() }

    public func withCurrent<T>(_ action: () throws -> T) throws -> T {
        try requireCurrent()
        let result = try action()
        try requireCurrent()
        return result
    }

    public static func validate(
        _ admissions: [Self], available: [URL], markerKeys: Set<String>
    ) throws {
        guard !admissions.isEmpty, admissions.count <= 3, available.count <= 3,
            Set(admissions.map(\.roleDirectory)).count == admissions.count
        else { throw Failure.rejected }
        for admission in admissions {
            guard admission.roleDirectory.isFileURL,
                admission.roleDirectory == admission.roleDirectory.standardizedFileURL,
                available.contains(admission.roleDirectory),
                ["app.bundle", "helper.bundle", "agent.bundle"].contains(
                    admission.roleDirectory.lastPathComponent),
                Set(admission.contextMarker.keys) == markerKeys,
                admission.contextMarker.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 })
            else { throw Failure.rejected }
            try admission.requireCurrent()
        }
    }
}
#endif
