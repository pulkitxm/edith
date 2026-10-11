import CryptoKit
import Foundation
import Testing
@testable import WorkerFixtureSupport

struct WorkerFixtureRolePolicyTests {
    private let hash = String(repeating: "b", count: 64)

    @Test func primaryRolesMatchMaintainedOriginalManifest() throws {
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "manifest.json")
        let entries =
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [[String: Any]]
        let actualHelpers = Set(
            entries.filter { Set(($0["roles"] as! [String: Any]).keys) == ["helper"] }.map {
                $0["id"] as! String
            })
        #expect(actualHelpers == WorkerFixtureUIContract.helperOwners)
        #expect(actualHelpers.count == 11)
        #expect(Set(entries.map { $0["id"] as! String }) == WorkerFixtureUIContract.owners)
        for entry in entries {
            let owner = entry["id"] as! String
            let role: WorkerFixtureRole = actualHelpers.contains(owner) ? .helper : .app
            _ = try policy(owner, role: role)
            #expect(throws: (any Error).self) {
                try policy(owner, role: role == .helper ? .app : .helper)
            }
        }
    }

    private func policy(_ owner: String, role: WorkerFixtureRole) throws -> WorkerFixtureRolePolicy
    {
        try WorkerFixtureRolePolicy(
            owner: owner, primaryRole: role, operations: [owner + ".probe"],
            presentations: [try WorkerFixturePresentationScope(location: "main", section: owner)],
            inputs: [], outputs: [], manifestSHA256: hash, caseSHA256: hash)
    }

    @Test func closedCapabilityTableRejectsDuplicateUnownedAndUnboundedScopes() throws {
        for owner in ["foreign", "plugins/helper", "com.pulkit.edith"] {
            #expect(throws: (any Error).self) { try policy(owner, role: .helper) }
        }
        for operations in [
            [], ["keepAwake.probe", "keepAwake.probe"], ["keepAwake.probe", "../foreign"],
        ] {
            #expect(throws: (any Error).self) {
                try WorkerFixtureRolePolicy(
                    owner: "keepAwake", primaryRole: .helper, operations: operations,
                    presentations: [
                        try WorkerFixturePresentationScope(location: "main", section: "keepAwake")
                    ], inputs: [], outputs: [], manifestSHA256: hash, caseSHA256: hash)
            }
        }
        #expect(throws: (any Error).self) {
            try WorkerFixtureInputScope(name: "agents", maximumBytes: 268_435_457)
        }
        #expect(throws: (any Error).self) {
            try WorkerFixturePresentationScope(location: "panel", section: "keepAwake")
        }
        #expect(throws: (any Error).self) {
            try WorkerFixtureRolePolicy(
                owner: "keepAwake", primaryRole: .helper, operations: ["keepAwake.probe"],
                presentations: [
                    try WorkerFixturePresentationScope(location: "main", section: "clipboard")
                ], inputs: [], outputs: [], manifestSHA256: hash, caseSHA256: hash)
        }
    }
}
