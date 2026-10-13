import Darwin
import Foundation
import Testing

@testable import FunctionalProducerModels

struct FunctionalBlitzTreeSavedReaderTests {
    private let session = "00000000-0000-4000-8000-000000000001"
    private let seed = Data(repeating: 42, count: 4096)

    private func definition(owner: String = "blitztree") throws -> Data {
        let absent: [String: Any] = ["bytes": ["present": false], "sha256": ["present": false]]
        let present: [String: Any] = [
            "bytes": ["present": true, "value": 4096],
            "sha256": ["present": true, "value": FunctionalBytes.digest(seed)],
        ]
        return try FunctionalBytes.canonical([
            "schema": 1, "owner": owner,
            "reads": zip(["victim", "private-trash"], ["scan", "trash"]).map { name, directory in
                [
                    "name": name, "root": "owner-outputs",
                    "components": [["derived": "phase"], directory, "victim.bin"],
                    "maximumBytes": 4096, "format": "raw-file",
                    "selections": [
                        ["name": "bytes", "path": ["bytes"], "codec": "value"],
                        ["name": "sha256", "path": ["sha256"], "codec": "value"],
                    ],
                ] as [String: Any]
            },
            "sentinels": [], "initial": ["victim": present, "private-trash": absent],
            "final": ["victim": absent, "private-trash": present],
        ])
    }

    private func fixture() throws -> URL {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: temporary).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let canonical = realpath(root.path, nil) else {
            try? FileManager.default.removeItem(at: root)
            throw FunctionalFailure.invalid("physical synthetic root")
        }
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical))
    }

    private func prepare(_ root: URL, phase: String) throws -> (URL, URL) {
        let outputs = root.appendingPathComponent("outputs/blitztree/" + phase)
        for directory in ["scan", "trash"] {
            try FileManager.default.createDirectory(
                at: outputs.appendingPathComponent(directory), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let source = outputs.appendingPathComponent("scan/victim.bin")
        try seed.write(to: source, options: [.withoutOverwriting])
        guard chmod(source.path, 0o600) == 0 else { throw FunctionalFailure.invalid("seed mode") }
        return (source, outputs.appendingPathComponent("trash/victim.bin"))
    }

    private func reader(_ root: URL, phase: String, definition: Data? = nil) throws
        -> FunctionalOwnerSavedReader
    {
        try FunctionalOwnerSavedReader(
            owner: "blitztree", phase: phase,
            root: FunctionalPinnedPath(root, directory: true, privateMode: true),
            session: session, hostIdentifier: "com.pulkit.edith.tests.worker-" + session,
            definition: try definition ?? self.definition())
    }

    @Test func eachPhaseCapturesFreshBytesWithoutChangingTheRetainedPriorPhase() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var retained: [(FunctionalOwnerSavedReader, FunctionalOwnerSavedReader.RawObservation)] = []
        for phase in ["initial", "updated", "reinstalled"] {
            let (source, destination) = try prepare(root, phase: phase)
            let current = try reader(root, phase: phase)
            #expect(try current.read() == current.initialSaved)
            try FileManager.default.moveItem(at: source, to: destination)
            #expect(try current.read() == current.finalSaved)
            for (previous, observation) in retained {
                try previous.requirePreserved(since: observation)
            }
            retained.append((current, try current.observeSentinels()))
        }
        #expect(retained.count == 3)
    }

    private func requirePriorPhaseMutationRejected(_ changedPhase: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let phases = ["initial", "updated", "reinstalled"]
        var retained:
            [(
                phase: String, reader: FunctionalOwnerSavedReader,
                observation: FunctionalOwnerSavedReader.RawObservation
            )] = []
        var destinations: [String: URL] = [:]
        for phase in phases {
            let (source, destination) = try prepare(root, phase: phase)
            let current = try reader(root, phase: phase)
            try FileManager.default.moveItem(at: source, to: destination)
            #expect(try current.read() == current.finalSaved)
            retained.append((phase, current, try current.observeSentinels()))
            destinations[phase] = destination
        }
        try FunctionalOwnerSavedReader.requireBlitzTreePhasesPreserved(
            retained, completedPhases: phases)
        let changed = try #require(destinations[changedPhase])
        try Data(repeating: 7, count: 4096).write(to: changed)
        let latest = try #require(retained.last)
        try latest.reader.requirePreserved(since: latest.observation)
        #expect(throws: (any Error).self) {
            try FunctionalOwnerSavedReader.requireBlitzTreePhasesPreserved(
                retained, completedPhases: phases)
        }
    }

    @Test func initialMutationAfterReinstalledRetirementCannotPassFinalSavedClosure() throws {
        try requirePriorPhaseMutationRejected("initial")
    }

    @Test func updatedMutationAfterReinstalledRetirementCannotPassFinalSavedClosure() throws {
        try requirePriorPhaseMutationRejected("updated")
    }

    @Test func finalSavedClosureRequiresEveryCompletedPhaseExactlyOnce() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var retained:
            [(
                phase: String, reader: FunctionalOwnerSavedReader,
                observation: FunctionalOwnerSavedReader.RawObservation
            )] = []
        let phases = ["initial", "updated", "reinstalled"]
        for phase in phases {
            let (source, destination) = try prepare(root, phase: phase)
            let current = try reader(root, phase: phase)
            try FileManager.default.moveItem(at: source, to: destination)
            retained.append((phase, current, try current.observeSentinels()))
        }
        try FunctionalOwnerSavedReader.requireBlitzTreePhasesPreserved(
            Array(retained.prefix(2)), completedPhases: Array(phases.prefix(2)))
        #expect(throws: (any Error).self) {
            try FunctionalOwnerSavedReader.requireBlitzTreePhasesPreserved(
                Array(retained.suffix(2)), completedPhases: phases)
        }
        #expect(throws: (any Error).self) {
            try FunctionalOwnerSavedReader.requireBlitzTreePhasesPreserved(
                [retained[0], retained[0], retained[2]], completedPhases: phases)
        }
        #expect(throws: (any Error).self) {
            try FunctionalOwnerSavedReader.requireBlitzTreePhasesPreserved(
                Array(retained.reversed()), completedPhases: phases)
        }
    }

    @Test func actualMoveReadbackIncludesPresentBytesAndPreservesTheOriginalInode() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, destination) = try prepare(root, phase: "initial")
        let current = try reader(root, phase: "initial")
        let before = try current.observeSentinels()
        var initial = stat()
        #expect(lstat(source.path, &initial) == 0)
        try FileManager.default.moveItem(at: source, to: destination)
        var final = stat()
        #expect(lstat(destination.path, &final) == 0)
        #expect(initial.st_dev == final.st_dev && initial.st_ino == final.st_ino)
        #expect(try before.rawBytes(name: "victim") == seed)
        let after = try current.observeSentinels()
        #expect(try after.rawBytes(name: "victim") == nil)
        #expect(try after.rawBytes(name: "private-trash") == seed)
        #expect(after.saved == current.finalSaved)
        try current.requireUnchanged(since: after)
    }

    @Test func wrongBytesSubstitutionHardLinksAndPublicModesCannotPassTheSavedProof() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, destination) = try prepare(root, phase: "initial")
        let current = try reader(root, phase: "initial")
        let before = try current.observeSentinels()
        try FileManager.default.removeItem(at: source)
        try seed.write(to: source)
        #expect(chmod(source.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try current.requireUnchanged(since: before) }
        #expect(chmod(source.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try current.read() }
        #expect(chmod(source.path, 0o600) == 0)
        #expect(link(source.path, destination.path) == 0)
        #expect(throws: (any Error).self) { try current.read() }
        #expect(unlink(destination.path) == 0)
        try FileManager.default.moveItem(at: source, to: destination)
        try Data(repeating: 7, count: 4096).write(to: destination)
        #expect(try current.read() != current.finalSaved)
    }

    @Test func rawMetadataReaderRejectsForeignOwnerAndSecretOrUnboundedSelections() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try prepare(root, phase: "initial")
        let original = try FunctionalBytes.object(definition())
        let originalReads = try #require(original["reads"] as? [[String: Any]])
        for change in ["scope", "bound", "selection"] {
            var foreign = original
            var reads = originalReads
            var entry = reads[0]
            if change == "scope" { entry["root"] = "owner-home" }
            if change == "bound" { entry["maximumBytes"] = 4097 }
            if change == "selection" {
                entry["selections"] = [
                    ["name": "bytes", "path": ["contents"], "codec": "value"],
                    ["name": "sha256", "path": ["sha256"], "codec": "value"],
                ]
            }
            reads[0] = entry
            foreign["reads"] = reads
            #expect(throws: (any Error).self) {
                try reader(root, phase: "initial", definition: FunctionalBytes.canonical(foreign))
            }
        }
        #expect(throws: (any Error).self) {
            try reader(root, phase: "initial", definition: definition(owner: "music"))
        }
    }
}
