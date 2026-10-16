import Darwin
import Foundation
import WorkerFixtureSupport

@MainActor
final class FunctionalHeldPresentation {
    let capability: HostedFunctionalActionContext
    let capabilitySHA256: String
    let presentationID: String
    let location: String
    let section: String
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

    init(
        capabilityBytes: Data, presentationID: String, location: String, section: String,
        hostPID: Int32, expectedPhase: String, issuer: FunctionalIssuer
    ) throws {
        let context = try HostedFunctionalActionContext.decode(capabilityBytes)
        guard context.sourceCommit == FunctionalProducerBuild.sourceCommit,
            context.session == FunctionalProducerBuild.session,
            context.fixtureRoot == FunctionalProducerBuild.root,
            context.hostIdentifier == FunctionalProducerBuild.hostIdentifier,
            context.dataDirectory == context.fixtureRoot + "/Edith Tests/worker-" + context.session
                + "/Data/" + context.owner,
            context.pairScope == "synthetic-development", context.phase == expectedPhase,
            context.version == (expectedPhase == "initial" ? "1.0.0" : "1.1.0"),
            context.caseSHA256 == FunctionalProducerBuild.caseDigests[context.owner],
            context.operations == FunctionalProducerBuild.operations[context.owner],
            FunctionalProducerBuild.activationOperations[context.owner] != nil,
            context.activationOperation == FunctionalProducerBuild.activationOperations[
                context.owner]!,
            presentationID == (try Self.derivePresentationID(capabilityBytes)),
            let recipeBytes = FunctionalProducerBuild.recipes[context.owner],
            let policy = FunctionalProducerBuild.rolePolicies.first(where: {
                $0.owner == context.owner
            }),
            let phase = WorkerFixtureFilePhase(rawValue: expectedPhase)
        else { throw FunctionalFailure.invalid("compiled capability scope") }
        let recipe = try FunctionalBytes.object(recipeBytes)
        guard recipe["location"] as? String == location, recipe["section"] as? String == section,
            policy.operations == context.operations
        else {
            throw FunctionalFailure.invalid("independently compiled presentation and role policy")
        }
        let scopes = try policy.validateOwnedPaths(
            context.ownedPaths.map { entry in
                guard let kind = WorkerFixtureFileKind(rawValue: entry.kind) else {
                    throw FunctionalFailure.invalid("source file kind")
                }
                return WorkerFixtureOwnedPathClaim(name: entry.name, path: entry.path, kind: kind)
            }, owner: context.owner, root: FunctionalProducerBuild.root,
            session: FunctionalProducerBuild.session, phase: phase)
        fileScopes = try FunctionalFileScopes(
            resolved: scopes,
            root: FunctionalPinnedPath(
                URL(fileURLWithPath: FunctionalProducerBuild.root), directory: true,
                privateMode: true))
        compiledRecipe = recipe
        engine = try FunctionalBirth.observe(context.engine.pid)
        ui = try FunctionalBirth.observe(context.ui.pid)
        producer = try FunctionalBirth.observe(getpid())
        host = try FunctionalBirth.observe(hostPID)
        let observedEngine = try JSONDecoder().decode(
            HostedFunctionalProcessIdentity.self,
            from: FunctionalBytes.canonical(engine.contractObject))
        let observedUI = try JSONDecoder().decode(
            HostedFunctionalProcessIdentity.self, from: FunctionalBytes.canonical(ui.contractObject)
        )
        try context.validate(
            source: issuer.sourceCommit, owner: context.owner, session: issuer.session,
            uid: getuid(), root: FunctionalProducerBuild.root, caseSHA256: context.caseSHA256,
            operations: FunctionalProducerBuild.operations[context.owner]!,
            engine: observedEngine, ui: observedUI)
        let workerPath =
            context.fixtureRoot + "/Edith Tests/worker-" + context.session + "/Extensions/"
            + context.owner
            + "/edith-host-2/arm64/" + context.version + "/" + context.owner
            + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex"
        worker = URL(fileURLWithPath: workerPath)
        let selectedRole = policy.primaryRole.rawValue
        guard FunctionalProducerBuild.roles[context.owner]?.contains(selectedRole) == true else {
            throw FunctionalFailure.invalid("compiled original role map")
        }
        role = worker.appendingPathComponent(
            "Contents/Resources/Payload/" + context.owner + "/" + selectedRole + ".bundle")
        guard engine.executable == context.fixtureRoot + "/Fixture.app/Contents/MacOS/Edith",
            ui.executable == workerPath + "/Contents/MacOS/Edith",
            host.executable == context.fixtureRoot + "/Fixture.app/Contents/MacOS/Edith",
            producer.executable == context.fixtureRoot + "/Producer/functional-producer",
            Set([host.pid, producer.pid, engine.pid, ui.pid]).count == 4
        else { throw FunctionalFailure.invalid("original executable paths") }
        hostSigner = Self.signer(identifier: context.hostIdentifier)
        workerSigner = Self.signer(
            identifier: context.hostIdentifier + ".extension." + context.owner + ".worker")
        roleSigner = Self.signer(
            identifier: "com.pulkit.edith.extensions." + context.owner + "." + selectedRole)
        try hostSigner.verify(
            URL(fileURLWithPath: context.fixtureRoot + "/Fixture.app"), birth: host)
        try hostSigner.verify(
            URL(fileURLWithPath: context.fixtureRoot + "/Fixture.app"), birth: engine)
        try workerSigner.verify(worker, birth: ui)
        try roleSigner.verify(role)
        paths = try [
            context.fixtureRoot, context.home, context.dataDirectory, workerPath, role.path,
        ].map {
            try FunctionalPinnedPath(
                URL(fileURLWithPath: $0), directory: true,
                privateMode: $0 == context.fixtureRoot || $0 == context.home
                    || $0 == context.dataDirectory)
        }
        roleFiles = try Self.pinTree(role)
        self.capability = context
        self.capabilitySHA256 = FunctionalBytes.digest(capabilityBytes)
        self.presentationID = presentationID
        self.location = location
        self.section = section
    }

    func prepareAccessibilityActuator() throws {
        try requireCurrent()
        if originalUI != nil { return }
        var owned: [String: FunctionalOriginalUI.ChooserPath] = [:]
        for entry in capability.ownedPaths {
            owned[entry.name] = try FunctionalOriginalUI.ChooserPath(
                path: entry.path, kind: entry.kind, root: capability.fixtureRoot,
                owner: capability.owner)
        }
        originalUI = try FunctionalOriginalUI(
            host: host,
            windowTitle: "Synthetic functional " + capability.owner + " " + capability.phase + " "
                + capability.session,
            ownedPaths: owned,
            requireHeld: { [weak self] in
                guard let self else { throw FunctionalFailure.invalid("released presentation") }
                try self.requireCurrent()
            })
    }

    func originalStep(index: Int, requireNext: Bool = true) throws -> [String: Any] {
        try requireCurrent()
        guard let steps = compiledRecipe["steps"] as? [[String: Any]],
            (!requireNext || index == nextStep),
            index >= 0, index < steps.count
        else { throw FunctionalFailure.invalid("source recipe step order") }
        var expected = steps[index]
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
        var scope = try resolveLabel(
            expected["scope"] as? [String: Any] ?? [
                "kind": "window",
                "label": "Synthetic functional " + capability.owner + " " + capability.phase + " "
                    + capability.session,
            ])
        if let anchor = scope["anchor"] as? [String: Any] {
            scope["anchor"] = try resolveLabel(anchor)
        }
        expected["scope"] = scope
        if expected["ownedPath"] == nil { expected["ownedPath"] = NSNull() }
        return expected
    }

    func completeOriginalStep(index: Int, digest: String) throws {
        let step = try originalStep(index: index)
        guard FunctionalBytes.digest(try FunctionalBytes.canonical(step)) == digest else {
            throw FunctionalFailure.invalid("source actor original action digest")
        }
        nextStep += 1
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
        try hostSigner.verify(
            URL(fileURLWithPath: capability.fixtureRoot + "/Fixture.app"), birth: host)
        try hostSigner.verify(
            URL(fileURLWithPath: capability.fixtureRoot + "/Fixture.app"), birth: engine)
        try workerSigner.verify(worker, birth: ui)
        try roleSigner.verify(role)
    }

    func observedInventory(descriptors: [FunctionalPinnedPath]) async throws -> [String: Any] {
        try requireCurrent()
        guard descriptors.count == 2, capability.hostABI == "edith-host-2",
            let definition = FunctionalProducerBuild.caseDefinitions[capability.owner],
            FunctionalBytes.digest(definition) == capability.caseSHA256,
            let pins = FunctionalProducerBuild.sourceFiles as [String: String]?, !pins.isEmpty
        else {
            throw FunctionalFailure.invalid("missing actual original source inventory")
        }
        let repository = URL(fileURLWithPath: FunctionalProducerBuild.repository)
        let sourceRoot = try FunctionalPinnedPath(repository, directory: true)
        for (name, hash) in pins {
            guard !name.hasPrefix("/"),
                !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                    $0.isEmpty || $0 == "." || $0 == ".."
                }),
                FunctionalBytes.hex(hash, length: 64)
            else { throw FunctionalFailure.invalid("compiled original source path") }
            let file = try FunctionalPinnedPath(
                repository.appendingPathComponent(name), directory: false)
            guard FunctionalBytes.digest(try file.read()) == hash else {
                throw FunctionalFailure.invalid("original compiled source changed")
            }
        }
        try await Self.requireCleanSource(repository)
        try sourceRoot.requireCurrent()
        for descriptor in descriptors { try descriptor.requireCurrent(); _ = try descriptor.read() }
        let tree = try Self.pinTree(worker)
        let treeObject = Dictionary(
            uniqueKeysWithValues: tree.map {
                ($0.0.url.path.dropFirst(worker.path.count + 1).description, $0.1)
            })
        try requireCurrent()
        return [
            "sourceCommit": capability.sourceCommit, "sourceClean": true, "heldRootPinned": true,
            "heldDescriptorPinned": true, "hostSignatureVerified": true,
            "workerSignatureVerified": true,
            "roleSignatureVerified": true, "rolePayloadUnchanged": true, "factoryOverlay": false,
            "originalFactoriesUnchanged": true, "originalControlsUnchanged": true,
            "hostABI": capability.hostABI, "version": capability.version,
            "packageSHA256": capability.packageSHA256,
            "bundleTreeSHA256": FunctionalBytes.digest(try FunctionalBytes.canonical(treeObject)),
            "engine": engine.contractObject, "ui": ui.contractObject,
            "presentationID": presentationID,
        ]
    }

    func evidenceAdmission(
        descriptors: [FunctionalPinnedPath], retired: [FunctionalBirth], issuer: FunctionalIssuer
    ) async throws -> FunctionalCollectedEvidence.AdmissionFacts {
        let inventory = try await observedInventory(descriptors: descriptors)
        for birth in retired {
            try birth.requireAbsent()
            guard birth != engine, birth != ui else {
                throw FunctionalFailure.invalid("retained original generation birth")
            }
        }
        let info = try FunctionalPinnedPath(
            role.appendingPathComponent("Contents/Info.plist"), directory: false
        ).read()
        guard
            let plist = try PropertyListSerialization.propertyList(from: info, format: nil)
                as? [String: Any],
            let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty,
            !executable.contains("/"), executable != ".", executable != ".."
        else {
            throw FunctionalFailure.invalid("source original role executable")
        }
        for path in [
            engine.executable, ui.executable,
            role.appendingPathComponent("Contents/MacOS/" + executable).path,
        ] {
            let bytes = try FunctionalPinnedPath(URL(fileURLWithPath: path), directory: false)
                .read()
            guard bytes.count >= 32,
                Array(bytes.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]
            else {
                throw FunctionalFailure.invalid("actual source-built arm64 native image")
            }
        }
        func identity(_ birth: FunctionalBirth) throws -> HostedFunctionalProcessIdentity {
            try JSONDecoder().decode(
                HostedFunctionalProcessIdentity.self,
                from: FunctionalBytes.canonical(birth.contractObject))
        }
        let observedEngine = try identity(engine)
        let observedUI = try identity(ui)
        var mismatchedBirthRejected = false
        do {
            try capability.validate(
                source: issuer.sourceCommit, owner: capability.owner, session: issuer.session,
                uid: getuid(), root: capability.fixtureRoot, caseSHA256: capability.caseSHA256,
                operations: capability.operations, engine: observedUI, ui: observedEngine)
        } catch { mismatchedBirthRejected = true }
        guard mismatchedBirthRejected else {
            throw FunctionalFailure.invalid(
                "original generation birth guard accepted foreign peers")
        }
        try requireCurrent()
        return .init(
            binding: .init(
                sourceCommit: capability.sourceCommit, session: capability.session,
                owner: capability.owner, caseSHA256: capability.caseSHA256, phase: capability.phase,
                capabilitySHA256: capabilitySHA256, presentationID: presentationID),
            observedHost: try identity(host),
            observedEngine: observedEngine, observedUI: observedUI,
            admission: .init(
                heldRootPinned: try FunctionalBytes.boolean(inventory, "heldRootPinned"),
                heldDescriptorPinned: try FunctionalBytes.boolean(
                    inventory, "heldDescriptorPinned"),
                sourceClean: try FunctionalBytes.boolean(inventory, "sourceClean"),
                sourcePinned: true,
                payloadSignatureVerified: try FunctionalBytes.boolean(
                    inventory, "roleSignatureVerified"),
                architectureVerified: true, hostABIVerified: capability.hostABI == "edith-host-2",
                originalFactoryUnchanged: try FunctionalBytes.boolean(
                    inventory, "originalFactoriesUnchanged"),
                originalControlsUnchanged: try FunctionalBytes.boolean(
                    inventory, "originalControlsUnchanged"),
                staleGenerationRejected: mismatchedBirthRejected))
    }

    static func requireCleanSource(_ repository: URL) async throws {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        process.arguments = [
            "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "diff", "--quiet",
            "--no-ext-diff", FunctionalProducerBuild.sourceCommit, "--",
        ]
        process.currentDirectoryURL = repository
        process.environment = [
            "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
        }
        if process.isRunning {
            let child = try FunctionalBirth.observe(process.processIdentifier)
            var kernel = proc_bsdinfo()
            guard
                proc_pidinfo(
                    child.pid, PROC_PIDTBSDINFO, 0, &kernel, Int32(MemoryLayout<proc_bsdinfo>.size))
                    == MemoryLayout<proc_bsdinfo>.size,
                kernel.pbi_ppid == getpid(), child.uid == getuid()
            else { throw FunctionalFailure.invalid("owned source check child changed") }
            try child.requireCurrent()
            process.terminate()
            let cleanup = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning && ContinuousClock.now < cleanup {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                        continuation.resume()
                    }
                }
            }
            if process.isRunning {
                try child.requireCurrent()
                guard kill(child.pid, SIGKILL) == 0 else {
                    throw FunctionalFailure.invalid("owned source check cleanup")
                }
                let killed = ContinuousClock.now.advanced(by: .seconds(5))
                while process.isRunning && ContinuousClock.now < killed {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                            continuation.resume()
                        }
                    }
                }
                guard !process.isRunning else {
                    throw FunctionalFailure.invalid("owned source check did not join")
                }
            }
            throw FunctionalFailure.invalid("actual original source check deadline")
        }
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw FunctionalFailure.invalid("actual original checked-out source differs")
        }
    }

    var recipe: [String: Any] { compiledRecipe }

    func requireCompletedOriginalSteps() throws {
        guard let steps = compiledRecipe["steps"] as? [[String: Any]], nextStep == steps.count
        else {
            throw FunctionalFailure.invalid("incomplete actual original controls")
        }
    }

    func requireObserver(_ caller: FunctionalBirth, engineReceiver: Bool) throws {
        try requireCurrent()
        guard caller == (engineReceiver ? engine : host) else {
            throw FunctionalFailure.invalid("original observer kernel source")
        }
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

    static func derivePresentationID(_ capabilityBytes: Data) throws -> String {
        let object = try FunctionalBytes.object(capabilityBytes)
        let digest = FunctionalBytes.digest(
            try FunctionalBytes.canonical(object.filter { !["engine", "ui"].contains($0.key) }))
        var bytes = stride(from: 0, to: 32, by: 2).map { offset -> UInt8 in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            return UInt8(digest[start..<digest.index(start, offsetBy: 2)], radix: 16)!
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let boundaries = [0, 8, 12, 16, 20, 32]
        return zip(boundaries, boundaries.dropFirst()).map { start, end in
            String(
                hex[
                    hex.index(
                        hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)]
            )
        }.joined(separator: "-")
    }

    static func signer(identifier: String) -> FunctionalSigner {
        return FunctionalSigner(
            identifier: identifier, certificateSHA256: FunctionalProducerBuild.certificateSHA256,
            requirement: "identifier \"" + identifier + "\"")
    }

    static func treePaths(_ root: URL) throws -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ])
        else { throw FunctionalFailure.invalid("role inventory") }
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard paths.count <= 10000 else {
                throw FunctionalFailure.invalid("role inventory bound")
            }
            let state = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard state.isSymbolicLink != true,
                state.isRegularFile == true || state.isDirectory == true
            else { throw FunctionalFailure.invalid("role tree kind") }
            if state.isRegularFile == true { paths.append(url.path) }
        }
        return paths.sorted()
    }

    static func pinTree(_ root: URL) throws -> [(FunctionalPinnedPath, String)] {
        try treePaths(root).map { path in
            let opened = try FunctionalPinnedPath(URL(fileURLWithPath: path), directory: false)
            return (opened, FunctionalBytes.digest(try opened.read()))
        }
    }
}

@MainActor
final class FunctionalHostBridge {
    private let root: FunctionalPinnedPath
    private let issuer: FunctionalIssuer
    private let producer: FunctionalBirth
    private var host: FunctionalBirth?
    private var manifest: Data?
    private var artifactBytes: Data?
    private var registeredHost: FunctionalBirth?
    private var hostJoined = false
    private var sessions = Set<String>()

    var isRegistered: Bool { host != nil }

    init(root: FunctionalPinnedPath, issuer: FunctionalIssuer, producer: FunctionalBirth) {
        self.root = root
        self.issuer = issuer
        self.producer = producer
    }

    func authorityMetadata(environment: [String: String]) async throws -> [String: Any] {
        _ = try await FunctionalHostedRunAdmission.observe(
            pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
        try root.requireCurrent()
        try producer.requireCurrent()
        let signer = FunctionalSigner(
            identifier: FunctionalProducerBuild.producerIdentifier,
            certificateSHA256: FunctionalProducerBuild.certificateSHA256,
            requirement: "identifier \"" + FunctionalProducerBuild.producerIdentifier + "\"")
        try signer.verify(URL(fileURLWithPath: producer.executable), birth: producer)
        guard FunctionalBytes.hex(FunctionalProducerBuild.sourceSHA256, length: 64),
            FunctionalBytes.hex(FunctionalProducerBuild.toolchainSHA256, length: 64)
        else { throw FunctionalFailure.invalid("compiled actual source and toolchain provenance") }
        let value: [String: Any] = [
            "schema": 2, "sourceCommit": issuer.sourceCommit,
            "runID": FunctionalProducerBuild.hostedRunPins.runID,
            "jobID": FunctionalProducerBuild.hostedRunPins.jobID,
            "session": issuer.session, "root": root.url.path,
            "hostIdentifier": FunctionalProducerBuild.hostIdentifier,
            "issuerPublicKey": issuer.publicKey.base64EncodedString(),
            "policySHA256": FunctionalProducerBuild.policySHA256,
            "producer": [
                "path": producer.executable, "executableSHA256": producer.executableSHA256,
                "certificateSHA256": signer.certificateSHA256.base64EncodedString(),
                "requirement": signer.requirement,
                "sourceSHA256": FunctionalProducerBuild.sourceSHA256,
                "toolchainSHA256": FunctionalProducerBuild.toolchainSHA256,
            ],
            "signing": [
                "hostRequirement": "identifier \"" + FunctionalProducerBuild.hostIdentifier + "\"",
                "hostCertificateSHA256": signer.certificateSHA256.base64EncodedString(),
                "workerCertificateSHA256": signer.certificateSHA256.base64EncodedString(),
                "roleCertificateSHA256": signer.certificateSHA256.base64EncodedString(),
            ],
        ]
        let bytes = try FunctionalBytes.canonical(value)
        if let manifest, manifest != bytes {
            throw FunctionalFailure.invalid("same-live issuer metadata changed")
        }
        manifest = bytes
        return value
    }

    func register(_ artifact: [String: Any], hostPID: Int32, environment: [String: String])
        async throws -> FunctionalBirth
    {
        guard host == nil, let manifest else {
            throw FunctionalFailure.invalid("Host registration order")
        }
        _ = try await FunctionalHostedRunAdmission.observe(
            pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
        try FunctionalBytes.exact(
            artifact,
            [
                "schema", "sourceCommit", "session", "root", "hostIdentifier", "issuerPublicKey",
                "issuerManifestSHA256", "host", "producer", "workerCertificateSHA256",
                "roleCertificateSHA256",
            ])
        guard try FunctionalBytes.integer(artifact, "schema") == 2,
            artifact["sourceCommit"] as? String == issuer.sourceCommit,
            artifact["session"] as? String == issuer.session,
            artifact["root"] as? String == root.url.path,
            artifact["hostIdentifier"] as? String == FunctionalProducerBuild.hostIdentifier,
            artifact["issuerPublicKey"] as? String == issuer.publicKey.base64EncodedString(),
            artifact["issuerManifestSHA256"] as? String == FunctionalBytes.digest(manifest),
            let suppliedProducer = artifact["producer"] as? [String: Any],
            let suppliedHost = artifact["host"] as? [String: Any]
        else { throw FunctionalFailure.invalid("same-live compiled Host artifact authority") }
        try FunctionalBytes.exact(suppliedProducer, ["path", "executableSHA256"])
        guard suppliedProducer["path"] as? String == producer.executable,
            suppliedProducer["executableSHA256"] as? String == producer.executableSHA256
        else { throw FunctionalFailure.invalid("actual producer artifact binding") }
        try FunctionalBytes.exact(
            suppliedHost, ["path", "executableSHA256", "certificateSHA256", "requirement"])
        let app = root.url.appendingPathComponent("Fixture.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Edith")
        let signer = FunctionalSigner(
            identifier: FunctionalProducerBuild.hostIdentifier,
            certificateSHA256: FunctionalProducerBuild.certificateSHA256,
            requirement: "identifier \"" + FunctionalProducerBuild.hostIdentifier + "\"")
        guard suppliedHost["path"] as? String == app.path,
            suppliedHost["executableSHA256"] as? String
                == (try FunctionalBytes.digest(
                    FunctionalPinnedPath(executable, directory: false).read())),
            suppliedHost["certificateSHA256"] as? String
                == signer.certificateSHA256.base64EncodedString(),
            suppliedHost["requirement"] as? String == signer.requirement,
            artifact["workerCertificateSHA256"] as? String
                == signer.certificateSHA256.base64EncodedString(),
            artifact["roleCertificateSHA256"] as? String
                == signer.certificateSHA256.base64EncodedString()
        else { throw FunctionalFailure.invalid("source-built signed Host pins") }
        try signer.verify(app)
        let observed = try FunctionalBirth.observe(hostPID)
        guard observed.executable == executable.path,
            observed.executableSHA256 == suppliedHost["executableSHA256"] as? String
        else {
            throw FunctionalFailure.invalid("independently reobserved compiled Host launch birth")
        }
        try signer.verify(app, birth: observed)
        host = observed
        registeredHost = observed
        artifactBytes = try FunctionalBytes.canonical(artifact)
        return observed
    }

    func forward(owner: String, operation: String, fields: [String: Any]) async throws -> [String:
        Any]
    {
        guard let host, HostedFunctionalActionContext.owners.contains(owner),
            [
                "create-session", "select-catalog", "install", "open-original",
                "read-original-state", "drain", "remove", "retire-session", "shutdown",
            ].contains(operation),
            fields.keys.allSatisfy({
                !["schema", "sourceCommit", "session", "requestID", "operation", "owner"].contains(
                    $0)
            })
        else { throw FunctionalFailure.invalid("owned Host forwarding selection") }
        try root.requireCurrent()
        try producer.requireCurrent()
        try host.requireCurrent()
        let requestID = UUID().uuidString.lowercased()
        let request = try FunctionalBytes.canonical(
            fields.merging([
                "schema": 1, "sourceCommit": issuer.sourceCommit,
                "session": issuer.session, "requestID": requestID, "operation": operation,
                "owner": owner,
            ]) { _, new in new })
        let path = root.url.path + "/h.sock"
        let signer = FunctionalSigner(
            identifier: FunctionalProducerBuild.hostIdentifier,
            certificateSHA256: FunctionalProducerBuild.certificateSHA256,
            requirement: "identifier \"" + FunctionalProducerBuild.hostIdentifier + "\"")
        let bytes = try await Task.detached(priority: .userInitiated) {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            let descriptor = try FunctionalSocketWire.connect(path: path, deadline: deadline)
            defer { close(descriptor) }
            let peer = try FunctionalSocketPeer(descriptor: descriptor)
            guard peer.birth == host else {
                throw FunctionalFailure.invalid("owned compiled Host peer")
            }
            try signer.verify(URL(fileURLWithPath: host.executable), birth: host)
            try FunctionalSocketWire.writeFrame(request, descriptor: descriptor, deadline: deadline)
            let response = try FunctionalSocketWire.readFrame(descriptor, deadline: deadline)
            try peer.birth.requireCurrent()
            return response
        }.value
        let response = try FunctionalBytes.object(bytes)
        guard response["schema"] as? Int == 1,
            response["sourceCommit"] as? String == issuer.sourceCommit,
            response["session"] as? String == issuer.session,
            response["requestID"] as? String == requestID,
            response["operation"] as? String == operation, response["owner"] as? String == owner
        else { throw FunctionalFailure.invalid("actual Host reply correlation") }
        if operation == "create-session" { sessions.insert(owner) }
        if operation == "retire-session" { sessions.remove(owner) }
        return response
    }

    func qualificationContext() async throws -> FunctionalEvidenceSealing.QualifiedContext {
        guard let manifest, let artifactBytes, let registeredHost, host == registeredHost,
            sessions.isEmpty, !hostJoined
        else { throw FunctionalFailure.invalid("missing actual registered qualification context") }
        try root.requireCurrent()
        try producer.requireCurrent()
        try registeredHost.requireCurrent()
        try FunctionalHeldPresentation.signer(
            identifier: FunctionalProducerBuild.producerIdentifier
        )
        .verify(URL(fileURLWithPath: producer.executable), birth: producer)
        try FunctionalHeldPresentation.signer(identifier: FunctionalProducerBuild.hostIdentifier)
            .verify(root.url.appendingPathComponent("Fixture.app"), birth: registeredHost)
        guard !FunctionalProducerBuild.sourceFiles.isEmpty else {
            throw FunctionalFailure.invalid("missing qualification source inventory")
        }
        for (name, hash) in FunctionalProducerBuild.sourceFiles {
            let file = try FunctionalPinnedPath(
                URL(fileURLWithPath: FunctionalProducerBuild.repository).appendingPathComponent(
                    name), directory: false)
            guard FunctionalBytes.digest(try file.read()) == hash else {
                throw FunctionalFailure.invalid("qualification source changed")
            }
        }
        try await FunctionalHeldPresentation.requireCleanSource(
            URL(fileURLWithPath: FunctionalProducerBuild.repository))
        func birth(_ value: FunctionalBirth) throws -> FunctionalEvidenceSealing.ProcessBirth {
            guard let seconds = Int64(exactly: value.birthSeconds),
                let micros = Int32(exactly: value.birthMicroseconds)
            else {
                throw FunctionalFailure.invalid("actual qualification birth range")
            }
            return .init(
                pid: value.pid, birthSeconds: seconds, birthMicroseconds: micros, uid: value.uid,
                executable: value.executable, executableSHA256: value.executableSHA256)
        }
        let pins = FunctionalProducerBuild.hostedRunPins
        return .init(
            schema: 1, sourceCommit: issuer.sourceCommit, mergeCommit: pins.mergeCommit,
            baseCommit: pins.baseCommit,
            session: issuer.session, root: root.url.path,
            hostIdentifier: FunctionalProducerBuild.hostIdentifier,
            issuerPublicKey: issuer.publicKey.base64EncodedString(),
            issuerManifestSHA256: FunctionalBytes.digest(manifest),
            artifactSHA256: FunctionalBytes.digest(artifactBytes),
            policySHA256: FunctionalProducerBuild.policySHA256,
            sourceSHA256: FunctionalProducerBuild.sourceSHA256,
            toolchainSHA256: FunctionalProducerBuild.toolchainSHA256,
            runID: pins.runID, jobID: pins.jobID, runAttempt: pins.runAttempt,
            workflowSHA256: pins.workflowSHA256,
            producer: try birth(producer), host: try birth(registeredHost))
    }

    func requireNaturalCompletion() throws {
        guard hostJoined, host == nil, sessions.isEmpty, let registeredHost else {
            throw FunctionalFailure.invalid("missing actual natural Host join")
        }
        try registeredHost.requireAbsent()
        try root.requireCurrent()
        try producer.requireCurrent()
    }

    func cancelAndJoin() async throws {
        if host == nil { return }
        for owner in sessions.sorted() {
            _ = try await forward(owner: owner, operation: "retire-session", fields: [:])
        }
        try await finish()
    }

    func finish() async throws {
        guard let host, sessions.isEmpty else {
            throw FunctionalFailure.invalid("missing owned Host completion or held sessions")
        }
        _ = try await forward(owner: "keepAwake", operation: "shutdown", fields: [:])
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do { try host.requireAbsent(); break } catch {
                guard ContinuousClock.now < deadline else {
                    throw FunctionalFailure.timeout("natural Host birth retirement")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        self.host = nil
        hostJoined = true
    }

}

@main
@MainActor
enum FunctionalProducer {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count == 1 else {
            throw FunctionalFailure.invalid("disposable hosted producer entry")
        }
        _ = try await FunctionalHostedRunAdmission.observe(
            pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
        let root = try FunctionalPinnedPath(
            URL(fileURLWithPath: FunctionalProducerBuild.root), directory: true, privateMode: true)
        for relative in [
            "downloads", "Edith Tests", "Edith Tests/worker-" + FunctionalProducerBuild.session,
            "Edith Tests/worker-" + FunctionalProducerBuild.session + "/Data",
        ] {
            let directory = root.url.appendingPathComponent(relative, isDirectory: true)
            _ = try FunctionalPinnedPath(
                directory.deletingLastPathComponent(), directory: true, privateMode: true)
            var state = stat()
            if lstat(directory.path, &state) != 0 {
                guard errno == ENOENT, mkdir(directory.path, 0o700) == 0 else {
                    throw FunctionalFailure.invalid("owned original installer namespace")
                }
            }
            let pinned = try FunctionalPinnedPath(directory, directory: true, privateMode: true)
            if relative == "downloads" {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
                else {
                    throw FunctionalFailure.invalid(
                        "installer download namespace already populated")
                }
            }
            try pinned.requireCurrent()
        }
        try root.requireCurrent()
        let issuer = try FunctionalIssuer(
            sourceCommit: FunctionalProducerBuild.sourceCommit,
            session: FunctionalProducerBuild.session)
        let birth = try FunctionalBirth.observe(getpid())
        guard birth.executable == root.url.path + "/Producer/functional-producer"
        else { throw FunctionalFailure.invalid("producer executable") }
        let bridge = FunctionalHostBridge(root: root, issuer: issuer, producer: birth)
        let receiver = try FunctionalProducerReceiver(
            root: root, issuer: issuer, producer: birth, bridge: bridge)
        try emit([
            "schema": 1, "kind": "bootstrap", "sourceCommit": issuer.sourceCommit,
            "session": issuer.session, "issuerPublicKey": issuer.publicKey.base64EncodedString(),
            "producer": birth.object,
        ])
        var held: FunctionalHeldPresentation?
        var phaseOrder: [String: Int] = [:]
        var qualificationSealed = false
        let protocolCounts = [
            "seal-catalog": 2, "host-command": 16, "prepare-generation": 3,
            "held-generation": 3, "register-xctest-actor": 3, "xctest-step-observations": 3,
            "collect-drain": 3, "retired": 3, "capture-before-construction": 3, "read-saved": 3,
            "seal-presentation-proof": 3, "seal-owner-proof": 1, "original-ui-receipt": 3,
        ]
        _ = try HostedFunctionalActionContext.owners.reduce(0) { total, owner in
            guard let bytes = FunctionalProducerBuild.recipes[owner],
                let steps = try FunctionalBytes.object(bytes)["steps"] as? [[String: Any]],
                !steps.isEmpty, steps.count <= 16
            else { throw FunctionalFailure.invalid("literal recipe command budget") }
            return total + steps.count
        }
        let commandLimit =
            4 + HostedFunctionalActionContext.owners.count * protocolCounts.values.reduce(0, +)
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
                try root.requireCurrent()
                try birth.requireCurrent()
                count += 1
                guard count <= commandLimit else {
                    throw FunctionalFailure.invalid("producer command bound")
                }
                let command = try FunctionalBytes.object(commandBytes)
                guard let requestID = command["requestID"] as? String,
                    FunctionalBytes.uuid(requestID),
                    let operation = command["operation"] as? String
                else { throw FunctionalFailure.invalid("producer command correlation") }
                if qualificationSealed {
                    guard ["finish", "cancel"].contains(operation) else {
                        throw FunctionalFailure.invalid("command after actual qualified retirement")
                    }
                    try bridge.requireNaturalCompletion()
                } else {
                    try receiver.requireHealthy()
                }
                switch operation {
                case "cancel":
                    try FunctionalBytes.exact(command, ["requestID", "operation"])
                    try await bridge.cancelAndJoin()
                    try await receiver.closeAndJoin()
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "ownedCleanupComplete": true,
                    ])
                    return
                case "authority-metadata":
                    try FunctionalBytes.exact(command, ["requestID", "operation"])
                    let manifest = try await bridge.authorityMetadata(environment: environment)
                    try emit(["requestID": requestID, "operation": operation, "manifest": manifest])
                case "host-registration":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "artifact", "hostPID"])
                    guard let artifact = command["artifact"] as? [String: Any],
                        let hostPID = Int32(
                            exactly: try FunctionalBytes.integer(command, "hostPID"))
                    else { throw FunctionalFailure.invalid("actual Host artifact object") }
                    let host = try await bridge.register(
                        artifact, hostPID: hostPID, environment: environment)
                    try receiver.bindHost(host)
                    try emit(["requestID": requestID, "operation": operation, "host": host.object])
                case "seal-catalog":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "version"])
                    guard bridge.isRegistered, let owner = command["owner"] as? String,
                        HostedFunctionalActionContext.owners.contains(owner),
                        let version = command["version"] as? String,
                        ["1.0.0", "1.1.0"].contains(version)
                    else {
                        throw FunctionalFailure.invalid("actual prepared package catalog selection")
                    }
                    let catalog = try issuer.signedCatalog(
                        owner: owner, version: version, root: root)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "catalog": catalog.base64EncodedString(),
                    ])
                case "host-command":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "command", "fields"])
                    guard let owner = command["owner"] as? String,
                        let selection = command["command"] as? String,
                        [
                            "create-session", "select-catalog", "install", "open-original", "drain",
                            "remove", "retire-session",
                        ].contains(selection),
                        let fields = command["fields"] as? [String: Any]
                    else { throw FunctionalFailure.invalid("actual original Host command") }
                    if selection == "open-original" {
                        _ = try await FunctionalHostedRunAdmission.observe(
                            pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
                    }
                    let response = try await bridge.forward(
                        owner: owner, operation: selection, fields: fields)
                    if selection == "open-original" {
                        try receiver.presentationReturned(owner: owner, response: response)
                    }
                    if selection == "drain" {
                        try receiver.acceptDrain(owner: owner, response: response)
                    }
                    if selection == "remove" {
                        let removal = try receiver.collectRemoval(owner: owner, response: response)
                        try emit([
                            "requestID": requestID, "operation": operation, "response": response,
                            "removal": try FunctionalBytes.object(removal),
                        ])
                        continue
                    }
                    try emit(["requestID": requestID, "operation": operation, "response": response])
                case "capture-before-construction":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard bridge.isRegistered, held == nil, let owner = command["owner"] as? String,
                        let phase = command["phase"] as? String, phaseOrder[owner, default: 0] < 3,
                        phase
                            == ["initial", "updated", "reinstalled"][phaseOrder[owner, default: 0]]
                    else { throw FunctionalFailure.invalid("early actual saved phase order") }
                    _ = try await FunctionalHostedRunAdmission.observe(
                        pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
                    let observation = try await receiver.captureBeforeConstruction(
                        owner: owner, phase: phase)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "observation": try FunctionalBytes.object(observation),
                    ])
                case "read-saved":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard let owner = command["owner"] as? String,
                        let phase = command["phase"] as? String
                    else { throw FunctionalFailure.invalid("actual saved reader scope") }
                    let observation = try await receiver.readSaved(owner: owner, phase: phase)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "observation": try FunctionalBytes.object(observation),
                    ])
                case "original-ui-receipt":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard let owner = command["owner"] as? String,
                        let phase = command["phase"] as? String
                    else {
                        throw FunctionalFailure.invalid("actual original UI receipt selector")
                    }
                    let receipt = try receiver.originalUIReceipt(owner: owner, phase: phase)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "receipt": try FunctionalBytes.object(receipt),
                    ])
                case "prepare-generation":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard bridge.isRegistered, held == nil, let owner = command["owner"] as? String,
                        let phase = command["phase"] as? String, phaseOrder[owner, default: 0] < 3,
                        phase
                            == ["initial", "updated", "reinstalled"][phaseOrder[owner, default: 0]]
                    else { throw FunctionalFailure.invalid("source-owned generation phase order") }
                    _ = try await FunctionalHostedRunAdmission.observe(
                        pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
                    let request = try receiver.prepareGeneration(owner: owner, phase: phase)
                    try emit([
                        "requestID": requestID, "operation": operation, "presentation": request,
                    ])
                case "held-generation":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard held == nil, let owner = command["owner"] as? String,
                        let phase = command["phase"] as? String
                    else {
                        throw FunctionalFailure.invalid("source-owned held generation selection")
                    }
                    let current = try await receiver.heldGeneration(owner: owner, phase: phase)
                    held = current
                    let capability = try FunctionalBytes.canonical(
                        JSONSerialization.jsonObject(with: JSONEncoder().encode(current.capability))
                    )
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "capability": try FunctionalBytes.object(capability),
                        "presentationID": current.presentationID,
                        "descriptor": try FunctionalBytes.object(
                            current.descriptor(
                                location: current.location, section: current.section, issuer: issuer
                            )),
                    ])
                case "register-xctest-actor":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase", "artifact"])
                    guard let held, let owner = command["owner"] as? String,
                        owner == held.capability.owner,
                        let phase = command["phase"] as? String, phase == held.capability.phase,
                        let artifact = command["artifact"] as? [String: Any]
                    else { throw FunctionalFailure.invalid("source-built XCTest actor selection") }
                    let registration = try receiver.registerXCTestActor(
                        held: held, artifact: artifact)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "registration": registration,
                    ])
                case "xctest-step-observations":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard let held, command["owner"] as? String == held.capability.owner,
                        command["phase"] as? String == held.capability.phase
                    else { throw FunctionalFailure.invalid("actual XCTest observation selection") }
                    let observations = try receiver.xctestStepObservations(held: held)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "observations": observations,
                    ])
                case "observe-rendered":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "role", "label", "scope"])
                    guard let held else {
                        throw FunctionalFailure.invalid("missing held rendered presentation")
                    }
                    try held.prepareAccessibilityActuator()
                    guard let original = held.originalUI,
                        let role = command["role"] as? String,
                        let label = command["label"] as? String,
                        let scope = command["scope"] as? [String: Any]
                    else { throw FunctionalFailure.invalid("rendered observation command") }
                    let observation = try original.observeRendered(
                        role: role, label: label,
                        scope: JSONDecoder().decode(
                            FunctionalOriginalUI.Step.Scope.self,
                            from: FunctionalBytes.canonical(scope)))
                    let envelope = try issuer.seal([
                        "schema": 1, "sourceCommit": issuer.sourceCommit,
                        "session": issuer.session, "owner": held.capability.owner,
                        "phase": held.capability.phase,
                        "capabilitySHA256": held.capabilitySHA256,
                        "presentationID": held.presentationID,
                        "reader": "independent-hosted-producer",
                        "observationID": observation.identifier,
                        "observationSHA256": observation.digest,
                    ])
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "observation": try FunctionalBytes.object(envelope),
                    ])
                case "collect-drain":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard let owner = command["owner"] as? String,
                        let phase = command["phase"] as? String
                    else { throw FunctionalFailure.invalid("actual drain selection") }
                    let receipt = try receiver.collectedDrain(owner: owner, phase: phase)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "receipt": try FunctionalBytes.object(receipt),
                    ])
                case "seal-owner-proof":
                    try FunctionalBytes.exact(command, ["requestID", "operation", "owner"])
                    guard let owner = command["owner"] as? String else {
                        throw FunctionalFailure.invalid("actual owner proof scope")
                    }
                    let proof = try receiver.sealOwnerProof(owner: owner)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "claim": try FunctionalBytes.object(proof.claimData),
                        "observation": try FunctionalBytes.object(proof.observationData),
                    ])
                case "seal-presentation-proof":
                    try FunctionalBytes.exact(
                        command, ["requestID", "operation", "owner", "phase"])
                    guard let owner = command["owner"] as? String,
                        let phase = command["phase"] as? String
                    else {
                        throw FunctionalFailure.invalid("actual presentation proof scope")
                    }
                    let observation = try receiver.sealPresentationProof(owner: owner, phase: phase)
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "observation": try FunctionalBytes.object(observation),
                    ])
                case "retired":
                    try FunctionalBytes.exact(command, ["requestID", "operation"])
                    guard let current = held else {
                        throw FunctionalFailure.invalid("no held generation")
                    }
                    try receiver.retire(current)
                    phaseOrder[current.capability.owner, default: 0] += 1
                    held = nil
                    try emit([
                        "requestID": requestID, "operation": operation, "ownedBirthsAbsent": true,
                    ])
                case "seal-qualified-evidence":
                    try FunctionalBytes.exact(command, ["requestID", "operation"])
                    guard !qualificationSealed, held == nil,
                        Set(phaseOrder.keys) == HostedFunctionalActionContext.owners,
                        phaseOrder.values.allSatisfy({ $0 == 3 })
                    else { throw FunctionalFailure.invalid("incomplete actual qualified journeys") }
                    _ = try await FunctionalHostedRunAdmission.observe(
                        pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
                    let proofs = try receiver.completedOwnerProofs()
                    let signals = try receiver.completedRetirementSignals()
                    let context = try await bridge.qualificationContext()
                    try await bridge.finish()
                    try await receiver.closeAndJoin()
                    try bridge.requireNaturalCompletion()
                    _ = try await FunctionalHostedRunAdmission.observe(
                        pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
                    let payload = try FunctionalEvidenceSealing.aggregate(
                        context: context, owners: proofs,
                        retirement: .init(
                            hostAbsent: true, receiverJoined: true, signalsSent: signals),
                        publicKey: issuer.publicKey)
                    let evidence = try issuer.seal(FunctionalBytes.object(payload))
                    qualificationSealed = true
                    try emit([
                        "requestID": requestID, "operation": operation,
                        "evidence": try FunctionalBytes.object(evidence),
                    ])
                case "finish":
                    try FunctionalBytes.exact(command, ["requestID", "operation"])
                    guard qualificationSealed, held == nil,
                        Set(phaseOrder.keys) == HostedFunctionalActionContext.owners,
                        phaseOrder.values.allSatisfy({ $0 == 3 })
                    else {
                        throw FunctionalFailure.invalid(
                            "incomplete exact original owner journeys on finish")
                    }
                    try bridge.requireNaturalCompletion()
                    try emit(["requestID": requestID, "operation": operation])
                    return
                default: throw FunctionalFailure.unavailable("unpublished producer operation")
                }
            }
            guard qualificationSealed, line.isEmpty, held == nil,
                Set(phaseOrder.keys) == HostedFunctionalActionContext.owners,
                phaseOrder.values.allSatisfy({ $0 == 3 })
            else {
                throw FunctionalFailure.invalid(
                    "controller closed before exact original journeys completed")
            }
            try bridge.requireNaturalCompletion()
        } catch {
            let original = error
            var cleanupFailures: [String] = []
            do { try await bridge.cancelAndJoin() } catch {
                cleanupFailures.append("original Host retirement: " + String(describing: error))
            }
            do { try await receiver.closeAndJoin() } catch {
                cleanupFailures.append("producer listener retirement: " + String(describing: error))
            }
            guard cleanupFailures.isEmpty else {
                throw FunctionalFailure.invalid(
                    String(describing: original) + "; " + cleanupFailures.joined(separator: "; "))
            }
            throw original
        }
    }

    private static func emit(_ object: [String: Any]) throws {
        FileHandle.standardOutput.write(try FunctionalBytes.canonical(object))
        FileHandle.standardOutput.write(Data([10]))
    }
}
