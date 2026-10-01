import EdithCore
import Foundation

enum DatabasePackIdentity {
    static let executableName = "edith-database"
    static let suffix = ".database"

    static func directory(in directories: AppDirectories = .current) -> URL {
        directories.configuration.appendingPathComponent("Database/pack", isDirectory: true)
    }

    static func executableURL(in directories: AppDirectories = .current) -> URL {
        directory(in: directories).appendingPathComponent(executableName)
    }

    static func counterpartIdentifier(for identifier: String) -> String? {
        if identifier.hasSuffix(suffix) {
            let base = String(identifier.dropLast(suffix.count))
            guard !base.isEmpty else { return nil }
            return base
        }
        guard !identifier.isEmpty else { return nil }
        return identifier + suffix
    }

    static func requirement(identifier: String, teamIdentifier: String?) -> String {
        anchored("identifier \"\(identifier)\"", teamIdentifier: teamIdentifier)
    }

    static func acceptedPeerRequirement(
        signingIdentifier: String,
        teamIdentifier: String?
    ) -> String? {
        guard !signingIdentifier.isEmpty else { return nil }
        var identifiers = ["identifier \"\(signingIdentifier)\""]
        if let counterpart = counterpartIdentifier(for: signingIdentifier) {
            identifiers.append("identifier \"\(counterpart)\"")
        }
        let identity =
            identifiers.count == 1
            ? identifiers[0]
            : "(\(identifiers.joined(separator: " or ")))"
        return anchored(identity, teamIdentifier: teamIdentifier)
    }

    private static func anchored(_ identity: String, teamIdentifier: String?) -> String {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return identity }
        return identity
            + " and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
