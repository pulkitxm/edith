import Foundation
import Testing
import WorkerFixtureSupport
@testable import FunctionalProducerModels

struct FunctionalBlitzTreePreparationTests {
    private let session = "d86a14e8-e19d-4818-87a1-07f033e9a313"

    private func files(phase: WorkerFixtureFilePhase? = nil) throws
        -> [FunctionalFileScopes.PreparationFile]
    {
        let policy = try WorkerFixtureRolePolicy(
            owner: "blitztree", primaryRole: .app, operations: ["blitztree.ui.scan"],
            presentations: [
                try WorkerFixturePresentationScope(location: "main", section: "blitztree")
            ], inputs: [], outputs: ["victim"],
            fileScopes: [
                try WorkerFixtureFileScope(
                    name: "victim", kind: .file, purpose: .mutableState, root: .ownerOutputs,
                    components: [.phase, .literal("scan"), .literal("victim.bin")],
                    maximumBytes: 4096, maximumEntries: 1, initialState: .present,
                    allowedStates: [.present, .absent], immutableFiles: [], mutableFiles: [])
            ], manifestSHA256: String(repeating: "a", count: 64),
            caseSHA256: String(repeating: "b", count: 64))
        let preparation = try FunctionalBytes.canonical([
            "schema": 1, "owner": "blitztree",
            "files": [
                [
                    "root": "owner-outputs",
                    "components": [
                        ["phase": true], ["literal": "scan"], ["literal": "victim.bin"],
                    ],
                    "bytesBase64": Data(repeating: 42, count: 4096).base64EncodedString(),
                    "maximumBytes": 4096,
                ]
            ],
        ])
        let root = "/private/synthetic/functional-fixture-" + session
        if let phase {
            return try FunctionalFileScopes.preparationFiles(
                owner: "blitztree", root: root, session: session, policy: policy,
                bytes: preparation, phase: phase)
        }
        return try FunctionalFileScopes.preparationFiles(
            owner: "blitztree", root: root, session: session, policy: policy,
            bytes: preparation)
    }

    @Test func actualAdmittedPhasesResolveToDistinctFreshVictims() throws {
        var paths = Set<String>()
        for phase in [WorkerFixtureFilePhase.initial, .updated, .reinstalled] {
            let resolved = try files(phase: phase)
            try #require(resolved.count == 1)
            let file = resolved[0]
            #expect(
                file.path.hasSuffix("/outputs/blitztree/" + phase.rawValue + "/scan/victim.bin"))
            #expect(file.maximumBytes == 4096)
            #expect(file.bytes == Data(repeating: 42, count: 4096))
            let inserted = paths.insert(file.path).inserted
            #expect(inserted)
        }
        #expect(paths.count == 3)
    }

    @Test func originalDefaultPreparationRetainsInitialPhase() throws {
        let implicit = try files()
        let explicit = try files(phase: .initial)
        let implicitPaths = implicit.map(\.path)
        let explicitPaths = explicit.map(\.path)
        let implicitBytes = implicit.map(\.bytes)
        let explicitBytes = explicit.map(\.bytes)
        #expect(implicitPaths == explicitPaths)
        #expect(implicitBytes == explicitBytes)
    }
}
