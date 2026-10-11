import Darwin
import Foundation
import WorkerFixtureSupport

@MainActor
final class FunctionalHeldPresentation {
    let capability: HostedFunctionalActionContext
    let capabilitySHA256: String
    let presentationID: String
    let engine: FunctionalBirth
    let ui: FunctionalBirth
    private let producer: FunctionalBirth
    private let host: FunctionalBirth
    private let hostSigner: FunctionalSigner
    private let workerSigner: FunctionalSigner
    private let roleSigner: FunctionalSigner
    private let paths: [FunctionalPinnedPath]
    private let role: URL
    private let worker: URL
    private let roleFiles: [(FunctionalPinnedPath, String)]
    private(set) var originalUI: FunctionalOriginalUI?
    private let compiledRecipe: [String: Any]
    private let fileScopes: FunctionalFileScopes
    private var nextStep = 0

    init(capabilityBytes: Data, presentationID: String, location: String, section: String,
        hostPID: Int32, expectedPhase: String, issuer: FunctionalIssuer) throws
    {
        let context = try HostedFunctionalActionContext.decode(capabilityBytes)
        guard context.sourceCommit == FunctionalProducerBuild.sourceCommit,
            context.session == FunctionalProducerBuild.session,
            context.fixtureRoot == FunctionalProducerBuild.root,
            context.hostIdentifier == FunctionalProducerBuild.hostIdentifier,
            context.dataDirectory == context.fixtureRoot + "/Edith Tests/worker-" + context.session + "/Data/" + context.owner,
            context.pairScope == "synthetic-development", context.phase == expectedPhase,
            context.version == (expectedPhase == "initial" ? "1.0.0" : "1.1.0"),
            context.caseSHA256 == FunctionalProducerBuild.caseDigests[context.owner],
            context.operations == FunctionalProducerBuild.operations[context.owner],
            context.activationOperation == FunctionalProducerBuild.activationOperations[context.owner],
            presentationID == Self.derivePresentationID(capabilityBytes),
            let recipeBytes = FunctionalProducerBuild.recipes[context.owner],
            let policy = FunctionalProducerBuild.rolePolicies.first(where: { $0.owner == context.owner }),
            let phase = WorkerFixtureFilePhase(rawValue: expectedPhase)
        else { throw FunctionalFailure.invalid("compiled capability scope") }
        let recipe = try FunctionalBytes.object(recipeBytes)
        guard recipe["location"] as? String == location, recipe["section"] as? String == section,
            policy.operations == context.operations
        else { throw FunctionalFailure.invalid("independently compiled presentation and role policy") }
        let scopes = try policy.validateOwnedPaths(context.ownedPaths.map { entry in
            guard let kind = WorkerFixtureFileKind(rawValue: entry.kind) else {
                throw FunctionalFailure.invalid("source file kind") }
            return WorkerFixtureOwnedPathClaim(name: entry.name, path: entry.path, kind: kind)
        }, owner: context.owner, root: FunctionalProducerBuild.root, session: FunctionalProducerBuild.session, phase: phase)
        fileScopes = try FunctionalFileScopes(resolved: scopes,
            root: FunctionalPinnedPath(URL(fileURLWithPath: FunctionalProducerBuild.root), directory: true, privateMode: true))
        compiledRecipe = recipe
        engine = try FunctionalBirth.observe(context.engine.pid)
        ui = try FunctionalBirth.observe(context.ui.pid)
        producer = try FunctionalBirth.observe(getpid())
        host = try FunctionalBirth.observe(hostPID)
        let observedEngine = try JSONDecoder().decode(HostedFunctionalProcessIdentity.self, from: FunctionalBytes.canonical(engine.contractObject))
        let observedUI = try JSONDecoder().decode(HostedFunctionalProcessIdentity.self, from: FunctionalBytes.canonical(ui.contractObject))
        try context.validate(source: issuer.sourceCommit, owner: context.owner, session: issuer.session,
            uid: getuid(), root: FunctionalProducerBuild.root, caseSHA256: context.caseSHA256, operations: FunctionalProducerBuild.operations[context.owner]!,
            engine: observedEngine, ui: observedUI)
        let workerPath = context.fixtureRoot + "/Edith Tests/worker-" + context.session + "/Extensions/" + context.owner
            + "/edith-host-2/arm64/" + context.version + "/" + context.owner
            + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex"
        worker = URL(fileURLWithPath: workerPath)
        let selectedRole = policy.primaryRole.rawValue
        guard FunctionalProducerBuild.roles[context.owner]?.contains(selectedRole) == true else {
            throw FunctionalFailure.invalid("compiled original role map") }
        role = worker.appendingPathComponent("Contents/Resources/Payload/" + context.owner + "/" + selectedRole + ".bundle")
        guard engine.executable == context.fixtureRoot + "/Fixture.app/Contents/MacOS/Edith",
            ui.executable == workerPath + "/Contents/MacOS/Edith",
            host.executable == context.fixtureRoot + "/Fixture.app/Contents/MacOS/Edith",
            producer.executable == context.fixtureRoot + "/Producer/functional-producer",
            Set([host.pid, producer.pid, engine.pid, ui.pid]).count == 4
        else { throw FunctionalFailure.invalid("original executable paths") }
        hostSigner = Self.signer(identifier: context.hostIdentifier)
        workerSigner = Self.signer(identifier: context.hostIdentifier + ".extension." + context.owner + ".worker")
        roleSigner = Self.signer(identifier: "com.pulkit.edith.extensions." + context.owner + "." + selectedRole)
        try hostSigner.verify(URL(fileURLWithPath: context.fixtureRoot + "/Fixture.app"), birth: host)
        try hostSigner.verify(URL(fileURLWithPath: context.fixtureRoot + "/Fixture.app"), birth: engine)
        try workerSigner.verify(worker, birth: ui)
        try roleSigner.verify(role)
        paths = try [context.fixtureRoot, context.home, context.dataDirectory, workerPath, role.path].map {
            try FunctionalPinnedPath(URL(fileURLWithPath: $0), directory: true,
                privateMode: $0 == context.fixtureRoot || $0 == context.home || $0 == context.dataDirectory)
        }
        roleFiles = try Self.pinTree(role)
        self.capability = context
        self.capabilitySHA256 = FunctionalBytes.digest(capabilityBytes)
        self.presentationID = presentationID
    }

    func prepareAccessibilityActuator() throws {
        try requireCurrent()
        if originalUI != nil { return }
        var owned: [String: FunctionalOriginalUI.ChooserPath] = [:]
        for entry in capability.ownedPaths {
            owned[entry.name] = try FunctionalOriginalUI.ChooserPath(path: entry.path, kind: entry.kind, root: capability.fixtureRoot, owner: capability.owner)
        }
        originalUI = try FunctionalOriginalUI(host: host,
            windowTitle: "Synthetic functional " + capability.owner + " " + capability.phase + " " + capability.session,
            ownedPaths: owned, requireHeld: { [weak self] in
                guard let self else { throw FunctionalFailure.invalid("released presentation") }
                try self.requireCurrent()
            })
    }

    func performOriginalStep(_ supplied: [String: Any]) async throws -> Bool {
        try prepareAccessibilityActuator()
        guard let originalUI, let steps = compiledRecipe["steps"] as? [[String: Any]],
            nextStep < steps.count else { throw FunctionalFailure.invalid("source recipe exhausted") }
        var expected = steps[nextStep]
        func resolveLabel(_ entry: [String: Any]) throws -> [String: Any] {
            var entry = entry
            if let reference = entry["ownedLabel"] as? [String: String] {
                guard reference["component"] == "basename", let name = reference["name"],
                    let path = capability.ownedPaths.first(where: { $0.name == name })
                else { throw FunctionalFailure.invalid("source-owned label binding") }
                entry["label"] = URL(fileURLWithPath: path.path).lastPathComponent
            }
            return entry
        }
        expected = try resolveLabel(expected)
        var scope = try resolveLabel(expected["scope"] as? [String: Any] ?? [
            "kind": "window", "label": "Synthetic functional " + capability.owner + " " + capability.phase + " " + capability.session,
        ])
        if let anchor = scope["anchor"] as? [String: Any] { scope["anchor"] = try resolveLabel(anchor) }
        expected["scope"] = scope
        if expected["ownedPath"] == nil { expected["ownedPath"] = NSNull() }
        guard try FunctionalBytes.canonical(expected) == FunctionalBytes.canonical(supplied)
        else { throw FunctionalFailure.invalid("caller-selected original action") }
        let decoded = try JSONDecoder().decode(FunctionalOriginalUI.Step.self, from: FunctionalBytes.canonical(expected))
        let result = try await originalUI.perform(decoded, deadline: .now.advanced(by: .seconds(30)))
        try requireCurrent()
        nextStep += 1
        return result
    }

    func descriptor(location: String, section: String, issuer: FunctionalIssuer) throws -> Data {
        try requireCurrent()
        return try issuer.seal([
            "schema": 1, "sourceCommit": capability.sourceCommit, "session": capability.session,
            "owner": capability.owner, "phase": capability.phase, "presentationID": presentationID,
            "location": location, "section": section, "capabilitySHA256": capabilitySHA256,
            "root": capability.fixtureRoot, "hostIdentifier": capability.hostIdentifier,
            "home": capability.home, "dataDirectory": capability.dataDirectory,
            "workerPath": worker.path, "rolePath": role.path, "version": capability.version,
            "hostABI": capability.hostABI, "packageSHA256": capability.packageSHA256,
            "producer": producer.object, "engine": engine.object, "ui": ui.object,
        ])
    }

    private func requireOriginalBytes() throws {
        try fileScopes.requireCurrent()
        for path in paths { try path.requireCurrent() }
        for (path, digest) in roleFiles {
            guard try FunctionalBytes.digest(path.read()) == digest
            else { throw FunctionalFailure.invalid("original role changed") }
        }
        guard try Self.treePaths(role) == roleFiles.map({ $0.0.url.path })
        else { throw FunctionalFailure.invalid("original role tree changed") }
        try hostSigner.verify(URL(fileURLWithPath: capability.fixtureRoot + "/Fixture.app"))
        try workerSigner.verify(worker)
        try roleSigner.verify(role)
    }

    func requireCurrent() throws {
        try requireOriginalBytes()
        try producer.requireCurrent()
        try host.requireCurrent()
        try engine.requireCurrent()
        try ui.requireCurrent()
        try hostSigner.verify(URL(fileURLWithPath: capability.fixtureRoot + "/Fixture.app"), birth: host)
        try hostSigner.verify(URL(fileURLWithPath: capability.fixtureRoot + "/Fixture.app"), birth: engine)
        try workerSigner.verify(worker, birth: ui)
        try roleSigner.verify(role)
    }

    func requireCompletedOriginalSteps() throws {
        guard let steps = compiledRecipe["steps"] as? [[String: Any]], nextStep == steps.count else {
            throw FunctionalFailure.invalid("incomplete actual original controls") }
    }

    func requireObserver(_ caller: FunctionalBirth, engineReceiver: Bool) throws {
        try requireCurrent()
        guard caller == (engineReceiver ? engine : host) else {
            throw FunctionalFailure.invalid("original observer kernel source") }
        try caller.requireCurrent()
    }

    func requireForwardingSource(_ caller: FunctionalBirth) throws {
        try requireObserver(caller, engineReceiver: false)
    }

    func requireRetired() throws {
        try requireOriginalBytes()
        try engine.requireAbsent()
        try ui.requireAbsent()
        originalUI = nil
    }

    static func derivePresentationID(_ capabilityBytes: Data) -> String {
        let digest = FunctionalBytes.digest(capabilityBytes)
        var bytes = stride(from: 0, to: 32, by: 2).map { offset -> UInt8 in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            return UInt8(digest[start..<digest.index(start, offsetBy: 2)], radix: 16)!
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let boundaries = [0, 8, 12, 16, 20, 32]
        return zip(boundaries, boundaries.dropFirst()).map { start, end in
            String(hex[hex.index(hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)])
        }.joined(separator: "-")
    }

    private static func signer(identifier: String) -> FunctionalSigner {
        return FunctionalSigner(identifier: identifier, certificateSHA256: FunctionalProducerBuild.certificateSHA256,
            requirement: "identifier \"" + identifier + "\"")
    }

    private static func treePaths(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        else { throw FunctionalFailure.invalid("role inventory") }
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard paths.count <= 10000 else { throw FunctionalFailure.invalid("role inventory bound") }
            let state = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard state.isSymbolicLink != true, state.isRegularFile == true || state.isDirectory == true
            else { throw FunctionalFailure.invalid("role tree kind") }
            if state.isRegularFile == true { paths.append(url.path) }
        }
        return paths.sorted()
    }

    private static func pinTree(_ root: URL) throws -> [(FunctionalPinnedPath, String)] {
        try treePaths(root).map { path in
            let opened = try FunctionalPinnedPath(URL(fileURLWithPath: path), directory: false)
            return (opened, FunctionalBytes.digest(try opened.read()))
        }
    }
}

@main
@MainActor
enum FunctionalProducer {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count == 1,
            environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["RUNNER_OS"] == "macOS", environment["GITHUB_REPOSITORY"] == "pulkitxm/edith",
            environment["GITHUB_EVENT_NAME"] == "workflow_dispatch",
            environment["GITHUB_SHA"] == FunctionalProducerBuild.sourceCommit,
            environment["EXPECTED_SOURCE_SHA"] == FunctionalProducerBuild.sourceCommit,
            environment["EDITH_HOSTED_FUNCTIONAL_ACTIONS"] == "1",
            ["65671483", "320458784"].contains(environment["GITHUB_ACTOR_ID"] ?? ""),
            ["refs/heads/main", "refs/heads/feat/extension-marketplace"].contains(environment["GITHUB_REF"] ?? "")
        else { throw FunctionalFailure.invalid("disposable hosted producer") }
        let root = try FunctionalPinnedPath(URL(fileURLWithPath: FunctionalProducerBuild.root), directory: true, privateMode: true)
        let issuer = try FunctionalIssuer(sourceCommit: FunctionalProducerBuild.sourceCommit, session: FunctionalProducerBuild.session)
        let birth = try FunctionalBirth.observe(getpid())
        guard birth.executable == root.url.path + "/Producer/functional-producer"
        else { throw FunctionalFailure.invalid("producer executable") }
        let receiver = try FunctionalProducerReceiver(root: root, issuer: issuer, producer: birth)
        try emit(["schema": 1, "kind": "bootstrap", "sourceCommit": issuer.sourceCommit,
            "session": issuer.session, "issuerPublicKey": issuer.publicKey.base64EncodedString(), "producer": birth.object])
        var held: FunctionalHeldPresentation?
        var phaseOrder: [String: Int] = [:]
        var count = 0
        let input = FileHandle.standardInput
        defer { try? input.close() }
        var line = Data()
        do {
            for try await byte in input.bytes {
                guard byte == 10 || line.count < 1_048_576 else {
                    throw FunctionalFailure.invalid("producer input bound")
                }
                if byte != 10 { line.append(byte); continue }
                let commandBytes = line
                line.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
                try receiver.requireHealthy()
                try root.requireCurrent()
                try birth.requireCurrent()
                count += 1
                guard count <= 1024 else { throw FunctionalFailure.invalid("producer command bound") }
                let command = try FunctionalBytes.object(commandBytes)
                guard let requestID = command["requestID"] as? String, FunctionalBytes.uuid(requestID),
                    let operation = command["operation"] as? String
                else { throw FunctionalFailure.invalid("producer command correlation") }
                switch operation {
                case "hold-original":
                    try FunctionalBytes.exact(command, ["requestID", "operation", "capability", "presentationID", "location", "section", "hostPID"])
                    guard held == nil, let capability = command["capability"] as? [String: Any],
                        let presentation = command["presentationID"] as? String,
                        let location = command["location"] as? String, let section = command["section"] as? String,
                        let hostPID = Int32(exactly: try FunctionalBytes.integer(command, "hostPID"))
                    else { throw FunctionalFailure.invalid("held original command") }
                    guard let owner = capability["owner"] as? String, HostedFunctionalActionContext.owners.contains(owner),
                        phaseOrder[owner, default: 0] < 3 else { throw FunctionalFailure.invalid("source-owned journey phase exhausted") }
                    let expectedPhase = ["initial", "updated", "reinstalled"][phaseOrder[owner, default: 0]]
                    let current = try FunctionalHeldPresentation(capabilityBytes: FunctionalBytes.canonical(capability),
                        presentationID: presentation, location: location, section: section, hostPID: hostPID,
                        expectedPhase: expectedPhase, issuer: issuer)
                    try receiver.hold(current)
                    held = current
                    let descriptor = try current.descriptor(location: location, section: section, issuer: issuer)
                    try emit(["requestID": requestID, "operation": operation, "descriptor": try FunctionalBytes.object(descriptor)])
                case "original-step":
                    try FunctionalBytes.exact(command, ["requestID", "operation", "step"])
                    guard let held, let step = command["step"] as? [String: Any]
                    else { throw FunctionalFailure.invalid("missing held original UI") }
                    let performed = try await held.performOriginalStep(step)
                    try held.requireCurrent()
                    try emit(["requestID": requestID, "operation": operation, "controlPerformed": performed,
                        "receiverObservationRequired": true, "presentationID": held.presentationID])
                case "observe-rendered":
                    try FunctionalBytes.exact(command, ["requestID", "operation", "role", "label", "scope"])
                    guard let held else { throw FunctionalFailure.invalid("missing held rendered presentation") }
                    try held.prepareAccessibilityActuator()
                    guard let original = held.originalUI,
                        let role = command["role"] as? String, let label = command["label"] as? String,
                        let scope = command["scope"] as? [String: Any]
                    else { throw FunctionalFailure.invalid("rendered observation command") }
                    let observation = try original.observeRendered(role: role, label: label,
                        scope: JSONDecoder().decode(FunctionalOriginalUI.Step.Scope.self, from: FunctionalBytes.canonical(scope)))
                    let envelope = try issuer.seal(["schema": 1, "sourceCommit": issuer.sourceCommit,
                        "session": issuer.session, "owner": held.capability.owner, "phase": held.capability.phase,
                        "capabilitySHA256": held.capabilitySHA256, "presentationID": held.presentationID,
                        "reader": "independent-hosted-producer", "observationID": observation.identifier,
                        "observationSHA256": observation.digest])
                    try emit(["requestID": requestID, "operation": operation, "observation": try FunctionalBytes.object(envelope)])
                case "retired":
                    try FunctionalBytes.exact(command, ["requestID", "operation"])
                    guard let current = held else { throw FunctionalFailure.invalid("no held generation") }
                    try receiver.retire(current)
                    phaseOrder[current.capability.owner, default: 0] += 1
                    held = nil
                    try emit(["requestID": requestID, "operation": operation, "ownedBirthsAbsent": true])
                case "finish":
                    try FunctionalBytes.exact(command, ["requestID", "operation"])
                    guard held == nil, Set(phaseOrder.keys) == HostedFunctionalActionContext.owners,
                        phaseOrder.values.allSatisfy({ $0 == 3 })
                    else { throw FunctionalFailure.invalid("incomplete exact original owner journeys on finish") }
                    try await receiver.closeAndJoin()
                    try emit(["requestID": requestID, "operation": operation, "producerJoinedByControllerRequired": true])
                    return
                default: throw FunctionalFailure.unavailable("unpublished producer operation")
                }
            }
            guard line.isEmpty, held == nil, Set(phaseOrder.keys) == HostedFunctionalActionContext.owners,
                phaseOrder.values.allSatisfy({ $0 == 3 })
            else { throw FunctionalFailure.invalid("controller closed before exact original journeys completed") }
            try await receiver.closeAndJoin()
        } catch {
            do { try await receiver.closeAndJoin() }
            catch { throw FunctionalFailure.invalid("actual producer receiver failed to join") }
            throw error
        }
    }

    private static func emit(_ object: [String: Any]) throws {
        FileHandle.standardOutput.write(try FunctionalBytes.canonical(object))
        FileHandle.standardOutput.write(Data([10]))
    }
}
