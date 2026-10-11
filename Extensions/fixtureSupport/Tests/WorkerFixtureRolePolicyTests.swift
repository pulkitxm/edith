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

    private func policy(
        _ owner: String, role: WorkerFixtureRole, fileScopes: [WorkerFixtureFileScope] = []
    ) throws -> WorkerFixtureRolePolicy {
        try WorkerFixtureRolePolicy(
            owner: owner, primaryRole: role, operations: [owner + ".probe"],
            presentations: [try WorkerFixturePresentationScope(location: "main", section: owner)],
            inputs: [], outputs: [], fileScopes: fileScopes, manifestSHA256: hash, caseSHA256: hash)
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
                    ], inputs: [], outputs: [], fileScopes: [], manifestSHA256: hash,
                    caseSHA256: hash)
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
                ], inputs: [], outputs: [], fileScopes: [], manifestSHA256: hash, caseSHA256: hash)
        }
    }

    private let session = "12345678-1234-4123-8123-123456789abc"
    private var root: String { "/private/synthetic/functional-fixture-" + session }

    private func file(
        _ name: String, components: [WorkerFixtureFileComponent] = [.literal("record.json")],
        purpose: WorkerFixtureFilePurpose = .immutableInput,
        root: WorkerFixtureFileRoot = .ownerData, bytes: Int = 4096,
        initial: WorkerFixtureFilePresence = .present,
        states: [WorkerFixtureFilePresence] = [.present]
    ) throws -> WorkerFixtureFileScope {
        try WorkerFixtureFileScope(
            name: name, kind: .file, purpose: purpose, root: root, components: components,
            maximumBytes: bytes, maximumEntries: 1, initialState: initial, allowedStates: states,
            immutableFiles: [], mutableFiles: [])
    }

    @Test func emptyPolicyAdmitsOnlyGenuinelyEmptyClaims() throws {
        let value = try policy("keepAwake", role: .helper)
        #expect(
            try value.validateOwnedPaths(
                [], owner: "keepAwake", root: root, session: session, phase: .initial
            ).isEmpty)
        #expect(throws: (any Error).self) {
            try value.validateOwnedPaths(
                [.init(name: "dummy", path: root + "/keepAwake-home/dummy", kind: .file)],
                owner: "keepAwake", root: root, session: session, phase: .initial)
        }
    }

    @Test func exactOwnedPathRejectsForeignNameOwnerKindRootAndTraversal() throws {
        let scope = try file("metadata")
        let value = try policy("companion", role: .app, fileScopes: [scope])
        let path = root + "/Edith Tests/worker-" + session + "/Data/companion/record.json"
        let claim = WorkerFixtureOwnedPathClaim(name: "metadata", path: path, kind: .file)
        #expect(
            try value.validateOwnedPaths(
                [claim], owner: "companion", root: root, session: session, phase: .initial)
                == [.init(scope: scope, path: path)])
        for bad in [
            WorkerFixtureOwnedPathClaim(name: "foreign", path: path, kind: .file),
            .init(name: "metadata", path: path, kind: .directory),
            .init(name: "metadata", path: root + "/Fixture.app/Contents/Info.plist", kind: .file),
            .init(
                name: "metadata",
                path: path.replacingOccurrences(
                    of: "/companion/", with: "/plugins/"), kind: .file),
            .init(name: "metadata", path: path + "/../foreign", kind: .file),
            .init(name: "metadata", path: path.lowercased(), kind: .file),
        ] {
            #expect(throws: (any Error).self) {
                try value.validateOwnedPaths(
                    [bad], owner: "companion", root: root, session: session, phase: .initial)
            }
        }
        for owner in ["foreign", "plugins"] {
            #expect(throws: (any Error).self) {
                try value.validateOwnedPaths(
                    [claim], owner: owner, root: root, session: session, phase: .initial)
            }
        }
        for badRoot in [root + "/extra", "/Users/actual", root + "-alternate"] {
            #expect(throws: (any Error).self) {
                try value.validateOwnedPaths(
                    [claim], owner: "companion", root: badRoot, session: session, phase: .initial)
            }
        }
    }

    @Test func phaseAndUUIDSpellingResolveOneExactSourceDerivedPath() throws {
        let scope = try file(
            "export", components: [.phase, .sessionUUID(.uppercase), .literal("export.mp4")],
            purpose: .initiallyAbsentOutput, root: .ownerOutputs,
            initial: .absent, states: [.absent, .present])
        let value = try policy("timeLapse", role: .app, fileScopes: [scope])
        for phase in [WorkerFixtureFilePhase.initial, .updated, .reinstalled] {
            let path =
                root + "/outputs/timeLapse/" + phase.rawValue + "/"
                + session.uppercased() + "/export.mp4"
            let claim = WorkerFixtureOwnedPathClaim(name: "export", path: path, kind: .file)
            #expect(
                try value.validateOwnedPaths(
                    [claim], owner: "timeLapse", root: root, session: session, phase: phase
                )
                .first?.path == path)
            for badPath in [
                path.replacingOccurrences(of: session.uppercased(), with: session),
                path.replacingOccurrences(of: "/" + phase.rawValue + "/", with: "/unverified/"),
            ] {
                #expect(throws: (any Error).self) {
                    try value.validateOwnedPaths(
                        [.init(name: "export", path: badPath, kind: .file)],
                        owner: "timeLapse", root: root, session: session, phase: phase)
                }
            }
        }
    }

    @Test func closedInventoriesRejectTraversalAliasesPrefixAndInventedCapacity() throws {
        for components in [[".."], ["/tmp"], ["a/b"], ["a\\b"], ["é"], [""]] {
            #expect(throws: (any Error).self) {
                try file("input", components: components.map { .literal($0) })
            }
        }
        func directory(_ files: [WorkerFixtureImmutableFileScope], bytes: Int, count: Int) throws {
            _ = try WorkerFixtureFileScope(
                name: "folder", kind: .directory, purpose: .immutableInput, root: .ownerHome,
                components: [.literal("folder")], maximumBytes: bytes, maximumEntries: count,
                initialState: .present, allowedStates: [.present],
                immutableFiles: files, mutableFiles: [])
        }
        try directory([], bytes: 0, count: 0)
        #expect(throws: (any Error).self) { try directory([], bytes: 4096, count: 1) }
        let a = try WorkerFixtureImmutableFileScope(components: ["Foo"], maximumBytes: 1)
        let b = try WorkerFixtureImmutableFileScope(components: ["foo"], maximumBytes: 1)
        let child = try WorkerFixtureImmutableFileScope(
            components: ["Foo", "child"], maximumBytes: 1)
        #expect(throws: (any Error).self) { try directory([a, b], bytes: 2, count: 2) }
        #expect(throws: (any Error).self) { try directory([a, child], bytes: 2, count: 3) }
        #expect(throws: (any Error).self) { try directory([child], bytes: 1, count: 1) }
        #expect(throws: (any Error).self) { try directory([a], bytes: 0, count: 1) }
        #expect(throws: (any Error).self) { try file("input", states: [.present, .absent]) }
        #expect(throws: (any Error).self) {
            try file("output", purpose: .mutableState, root: .ownerInputs)
        }
        #expect(throws: (any Error).self) {
            try file("output", purpose: .initiallyAbsentOutput, root: .ownerOutputs)
        }
        #expect(throws: (any Error).self) { try file("state", purpose: .mutableState, states: []) }
    }

    @Test func mutableDirectoryClosesExactLeafBoundsStatesAndNamedOverlap() throws {
        let leaf = try WorkerFixtureMutableFileScope(
            components: ["victim.bin"], maximumBytes: 4096,
            initialState: .present, allowedStates: [.present, .absent])
        let directory = try WorkerFixtureFileScope(
            name: "scan-directory", kind: .directory, purpose: .mutableState,
            root: .ownerOutputs, components: [.phase, .literal("scan")],
            maximumBytes: 4096, maximumEntries: 1, initialState: .present,
            allowedStates: [.present], immutableFiles: [], mutableFiles: [leaf])
        let victim = try file(
            "victim", components: [.phase, .literal("scan"), .literal("victim.bin")],
            purpose: .mutableState, root: .ownerOutputs, states: [.present, .absent])
        let path = root + "/outputs/blitztree/initial/scan"
        let claims: [WorkerFixtureOwnedPathClaim] = [
            .init(name: "scan-directory", path: path, kind: .directory),
            .init(name: "victim", path: path + "/victim.bin", kind: .file),
        ]
        let value = try policy("blitztree", role: .app, fileScopes: [directory, victim])
        let resolved = try value.validateOwnedPaths(
            claims, owner: "blitztree", root: root, session: session, phase: .initial)
        #expect(resolved[0].scope.mutableFiles == [leaf])
        #expect(resolved[1].scope.allowedStates == [.present, .absent])
        for bad in [
            try file(
                "victim", components: victim.components, purpose: .mutableState,
                root: .ownerOutputs, bytes: 8192, states: [.present, .absent]),
            try file(
                "victim", components: victim.components, purpose: .mutableState,
                root: .ownerOutputs, states: [.present]),
        ] {
            let badPolicy = try policy("blitztree", role: .app, fileScopes: [directory, bad])
            #expect(throws: (any Error).self) {
                try badPolicy.validateOwnedPaths(
                    claims, owner: "blitztree", root: root, session: session, phase: .initial)
            }
        }
    }

    @Test func duplicateClaimsAndFilesystemCaseAliasesCannotExpandAuthority() throws {
        let scopes = [
            try file("first", components: [.literal("Foo.json")]),
            try file("second", components: [.literal("foo.json")]),
        ]
        let value = try policy("companion", role: .app, fileScopes: scopes)
        let parent = root + "/Edith Tests/worker-" + session + "/Data/companion/"
        let claims: [WorkerFixtureOwnedPathClaim] = [
            .init(name: "first", path: parent + "Foo.json", kind: .file),
            .init(name: "second", path: parent + "foo.json", kind: .file),
        ]
        #expect(throws: (any Error).self) {
            try value.validateOwnedPaths(
                claims, owner: "companion", root: root, session: session, phase: .initial)
        }
        #expect(throws: (any Error).self) {
            try value.validateOwnedPaths(
                [claims[0], claims[0]], owner: "companion", root: root,
                session: session, phase: .initial)
        }
    }

    @Test func namedFilesCannotOwnDescendantsOrAliasIntermediateDirectories() throws {
        let parent = root + "/Edith Tests/worker-" + session + "/Data/companion/"
        for leaves in [["record", "record/child"], ["Foo/a", "foo/b"]] {
            let scopes = try leaves.enumerated().map { index, leaf in
                try file(
                    "item" + String(index),
                    components: leaf.components(separatedBy: "/").map {
                        WorkerFixtureFileComponent.literal($0)
                    })
            }
            let value = try policy("companion", role: .app, fileScopes: scopes)
            let claims = leaves.enumerated().map { index, leaf in
                WorkerFixtureOwnedPathClaim(
                    name: "item" + String(index), path: parent + leaf, kind: .file)
            }
            #expect(throws: (any Error).self) {
                try value.validateOwnedPaths(
                    claims, owner: "companion", root: root,
                    session: session, phase: .initial)
            }
        }
        let inventory = try ["Foo/a", "foo/b"].map {
            try WorkerFixtureImmutableFileScope(
                components: $0.components(separatedBy: "/"), maximumBytes: 1)
        }
        #expect(throws: (any Error).self) {
            try WorkerFixtureFileScope(
                name: "tree", kind: .directory, purpose: .immutableInput,
                root: .ownerData, components: [.literal("tree")], maximumBytes: 2,
                maximumEntries: 4, initialState: .present, allowedStates: [.present],
                immutableFiles: inventory, mutableFiles: [])
        }
    }

}
