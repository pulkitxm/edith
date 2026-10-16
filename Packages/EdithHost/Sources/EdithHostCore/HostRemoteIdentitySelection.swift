import Foundation

enum HostRemoteIdentitySelection {
    static func ids(_ values: [String]) throws -> Set<String> {
        guard values.count <= 64,
            values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
            Set(values).count == values.count
        else { throw HostWorkerError.rejected }
        return Set(values)
    }

    static func select(before: Set<String>, after: [String], verified: String?) throws -> String {
        _ = try ids(Array(before))
        let current = try ids(after)
        let introduced = current.subtracting(before)
        if introduced.count == 1, let selected = introduced.first { return selected }
        guard introduced.isEmpty else { throw HostWorkerError.rejected }
        if let verified, current.contains(verified) { return verified }
        guard current.count == 1, let selected = current.first else {
            throw HostWorkerError.rejected
        }
        return selected
    }
}
