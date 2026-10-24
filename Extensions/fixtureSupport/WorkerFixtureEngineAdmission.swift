import CryptoKit
import Darwin
import Foundation

public struct WorkerFixtureEngineRequest: Equatable, Sendable {
    public let token: UUID
    public let operation: String
    public let payloadSHA256: String
    public let generation: String
    let admission: UUID
}

@MainActor public final class WorkerFixtureEngineAdmission {
    private static let namespaceGrantsForProcess = WorkerFixtureNamespaceGrantBook()
    public let descriptor: WorkerFixtureEngineContract
    private let trust: WorkerFixtureUITrust
    private let paths: [WorkerFixtureUIOpenedPath]
    private let host: URL
    private let worker: URL
    private let role: URL
    private let requests: WorkerFixtureEngineRequestGate
    private let expectedRole: WorkerFixtureRole
    private let inputFiles: [String: WorkerFixtureUIOpenedPath]
    private let outputParents: [String: WorkerFixtureUIOpenedPath]
    private let outputScopes: [String: WorkerFixtureEngineOutputScope]
    private var grantedOutputs: Set<String> = []
    private var nativeExports: [WorkerFixtureNativeExportLease] = []
    private var namespaceGrants: [WorkerFixtureCooperativeNamespaceLease] = []
    private var grantedNamespaces: Set<String> = []
    private var namespaceAdmissionOpen = true
    private var admissionOpen = true

    private init(
        descriptor: WorkerFixtureEngineContract, trust: WorkerFixtureUITrust,
        paths: [WorkerFixtureUIOpenedPath], host: URL, worker: URL, role: URL,
        expectedRole: WorkerFixtureRole, inputFiles: [String: WorkerFixtureUIOpenedPath],
        outputParents: [String: WorkerFixtureUIOpenedPath],
        outputScopes: [String: WorkerFixtureEngineOutputScope]
    ) {
        self.descriptor = descriptor; self.trust = trust; self.paths = paths
        self.host = host; self.worker = worker; self.role = role; self.expectedRole = expectedRole
        self.inputFiles = inputFiles
        self.outputParents = outputParents; self.outputScopes = outputScopes
        requests = WorkerFixtureEngineRequestGate(
            operations: descriptor.operations, generation: descriptor.requestGeneration)
    }

    public static func current(
        extensionID: String, context: NSDictionary, roleBundle: Bundle,
        workerBundle suppliedWorkerBundle: Bundle? = nil,
        expectedRole suppliedRole: WorkerFixtureRole? = nil
    ) throws -> WorkerFixtureEngineAdmission? {
        let environment = ProcessInfo.processInfo.environment
        let intentBundle = suppliedWorkerBundle ?? .main
        let intent =
            environment["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || context["hostedFunctionalFixture"] != nil
            || environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            || (context["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.") == true
            || intentBundle.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
            || environment["EDITH_APPLICATION_IDENTIFIER"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || environment["EDITH_SHARED_DEFAULTS_SUITE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
        guard intent else { return nil }
        guard let trust = WorkerFixtureUITrustAnchor.admitted else {
            throw WorkerFixtureError.invalid
        }
        try trust.validate()
        let policy = try trust.rolePolicy(owner: extensionID)
        let expectedRole = suppliedRole ?? policy.primaryRole
        guard expectedRole == policy.primaryRole else { throw WorkerFixtureError.invalid }
        guard
            roleBundle.bundleURL.path.hasPrefix(
                WorkerFixtureUIContract.identityRoot(root: trust.root, session: trust.session)
                    + "/Extensions/" + extensionID + "/edith-host-2/arm64/")
        else { throw WorkerFixtureError.invalid }
        var workerURL = roleBundle.bundleURL
        for _ in 0..<5 { workerURL.deleteLastPathComponent() }
        guard let workerBundle = suppliedWorkerBundle ?? Bundle(url: workerURL) else {
            throw WorkerFixtureError.invalid
        }
        try WorkerFixtureEngineContract.validateContext(
            context, environment: environment, owner: extensionID,
            workerIdentifier: workerBundle.bundleIdentifier ?? "")
        let documentPath = trust.root + "/functional-engine-" + extensionID + ".json"
        guard let marker = context["hostedFunctionalFixture"] as? [String: String],
            Set(marker.keys) == [
                "sourceCommit", "session", "phase", "descriptorPath", "capabilitySHA256",
                "requestGeneration",
            ],
            marker["sourceCommit"] == trust.sourceCommit, marker["session"] == trust.session,
            marker["descriptorPath"] == documentPath,
            context["hostIdentifier"] as? String == trust.hostIdentifier,
            context["dataDirectory"] as? String == WorkerFixtureUIContract.identityRoot(
                root: trust.root, session: trust.session)
                + "/Data/" + extensionID,
            environment["HOME"] == trust.root + "/" + extensionID + "-home",
            environment["CFFIXED_USER_HOME"] == environment["HOME"],
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == environment["HOME"],
            environment["EDITH_EXTENSION_DATA_ROOT"] == context["dataDirectory"] as? String
        else { throw WorkerFixtureError.invalid }
        let root = URL(fileURLWithPath: trust.root, isDirectory: true)
        var paths = [
            try WorkerFixtureUIOpenedPath(root, directory: true, mode: 0o700, maximum: nil)
        ]
        let document = try WorkerFixtureUIOpenedPath(
            URL(fileURLWithPath: documentPath), directory: false, mode: 0o600, maximum: 131_072)
        paths.append(document)
        let descriptor = try WorkerFixtureEngineContract.verify(
            document.read(), issuerKey: trust.issuerKey)
        try descriptor.validate(
            trust: trust, owner: extensionID, uid: getuid(), expectedRole: expectedRole)
        guard marker["phase"] == descriptor.phase,
            marker["capabilitySHA256"] == descriptor.capabilitySHA256,
            marker["requestGeneration"] == descriptor.requestGeneration,
            workerBundle.bundleURL.path == descriptor.workerPath,
            roleBundle.bundleURL.path == descriptor.rolePath,
            workerBundle.bundleIdentifier == trust.hostIdentifier + ".extension." + extensionID
                + ".worker",
            roleBundle.bundleIdentifier == "com.pulkit.edith.extensions." + extensionID + "."
                + descriptor.role,
            workerBundle.object(forInfoDictionaryKey: "EdithExtensionID") as? String == extensionID,
            workerBundle.object(forInfoDictionaryKey: "EdithExtensionVersion") as? String
                == descriptor.version,
            workerBundle.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String
                == trust.hostIdentifier,
            workerBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == descriptor.hostABI,
            workerBundle.object(forInfoDictionaryKey: "EdithHostExecutablePath") as? String == trust
                .root + "/Fixture.app/Contents/MacOS/Edith",
            roleBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == descriptor.version,
            roleBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == descriptor.hostABI,
            descriptor.engine.pid == getpid(),
            descriptor.engine.executable == trust.root + "/Fixture.app/Contents/MacOS/Edith",
            Bundle.main.executableURL?.path == descriptor.engine.executable
        else { throw WorkerFixtureError.invalid }
        let host = root.appendingPathComponent("Fixture.app", isDirectory: true)
        guard let bundle = Bundle(url: host),
            bundle.object(forInfoDictionaryKey: "EdithHostedFunctionalSession") as? String
                == trust.session,
            bundle.object(forInfoDictionaryKey: "EdithHostedFunctionalSourceCommit") as? String
                == trust.sourceCommit
        else { throw WorkerFixtureError.invalid }
        for path in [descriptor.home, descriptor.dataDirectory] {
            paths.append(
                try WorkerFixtureUIOpenedPath(
                    URL(fileURLWithPath: path), directory: true, mode: 0o700, maximum: nil))
        }
        for path in [host.path, descriptor.workerPath, descriptor.rolePath] {
            let bundle = URL(fileURLWithPath: path, isDirectory: true)
            paths.append(
                try WorkerFixtureUIOpenedPath(bundle, directory: true, mode: nil, maximum: nil))
            paths.append(
                try WorkerFixtureUIOpenedPath(
                    bundle.appendingPathComponent("Contents/Info.plist"), directory: false,
                    mode: nil, maximum: 131_072))
        }
        var inputFiles: [String: WorkerFixtureUIOpenedPath] = [:]
        for input in descriptor.inputs {
            let file = try WorkerFixtureUIOpenedPath(
                URL(fileURLWithPath: input.path), directory: false, mode: nil,
                maximum: input.maximumBytes)
            guard WorkerFixtureUIAdmission.digest(try file.read()) == input.sha256 else {
                throw WorkerFixtureError.invalid
            }
            paths.append(file); inputFiles[input.name] = file
        }
        var outputParents: [String: WorkerFixtureUIOpenedPath] = [:]
        for parent in Set(descriptor.outputs.map(\.parent)) {
            let opened = try WorkerFixtureUIOpenedPath(
                URL(fileURLWithPath: parent), directory: true, mode: 0o700, maximum: nil)
            paths.append(opened); outputParents[parent] = opened
        }
        var outputScopes: [String: WorkerFixtureEngineOutputScope] = [:]
        for output in descriptor.outputs {
            outputScopes[output.name] = try WorkerFixtureEngineOutputScope(
                output: output, policy: policy, root: trust.root, session: trust.session,
                phase: descriptor.phase)
        }
        let admission = WorkerFixtureEngineAdmission(
            descriptor: descriptor, trust: trust, paths: paths,
            host: host, worker: workerBundle.bundleURL, role: roleBundle.bundleURL,
            expectedRole: expectedRole, inputFiles: inputFiles,
            outputParents: outputParents, outputScopes: outputScopes)
        for output in descriptor.outputs { try admission.validateOutput(output, initial: true) }
        try admission.requireCurrent()
        return admission
    }

    public func requireCurrent() throws {
        guard admissionOpen else { throw WorkerFixtureError.invalid }
        try requireAuthorityCurrent()
    }

    private func requireAuthorityCurrent() throws {
        try trust.validate()
        try paths.forEach { try $0.validate() }
        let executable = try WorkerFixtureUIOpenedPath(
            host.appendingPathComponent("Contents/MacOS/Edith"), directory: false, mode: nil,
            maximum: 268_435_456)
        guard WorkerFixtureUIAdmission.digest(try executable.read()) == trust.hostExecutableSHA256,
            try WorkerFixtureUIAdmission.observe(descriptor.producer) == descriptor.producer,
            try WorkerFixtureUIAdmission.observe(descriptor.engine) == descriptor.engine,
            try WorkerFixtureUIAdmission.verifySignature(
                host, identifier: trust.hostIdentifier, requirement: trust.hostRequirement)
                == trust.hostCertificateSHA256,
            try WorkerFixtureUIAdmission.verifySignature(
                worker,
                identifier: trust.hostIdentifier + ".extension." + descriptor.owner + ".worker",
                requirement: nil) == trust.workerCertificateSHA256,
            descriptor.role == expectedRole.rawValue
        else { throw WorkerFixtureError.invalid }
        let roleIdentifier =
            "com.pulkit.edith.extensions." + descriptor.owner + "." + expectedRole.rawValue
        try descriptor.requireObservedRole(
            identifier: roleIdentifier, path: role.path,
            certificate: WorkerFixtureUIAdmission.verifySignature(
                role, identifier: roleIdentifier, requirement: nil),
            expectedRole: expectedRole, trust: trust)
        for output in descriptor.outputs { try validateOutput(output, initial: false) }
        try paths.forEach { try $0.validate() }
    }

    public func beginRequest(token: UUID, operation: String, payload: Data) throws
        -> WorkerFixtureEngineRequest
    {
        try requireCurrent()
        return try requests.begin(token: token, operation: operation, payload: payload)
    }
    public func completeRequest(_ request: WorkerFixtureEngineRequest) throws {
        guard requests.contains(request) else { throw WorkerFixtureError.invalid }
        try requireAuthorityCurrent()
        try requests.complete(request)
    }
    public func cancelRequest(_ request: WorkerFixtureEngineRequest) { requests.cancel(request) }
    public func readInput(named name: String) throws -> Data {
        try requireCurrent()
        guard let input = descriptor.inputs.first(where: { $0.name == name }),
            let file = inputFiles[name]
        else { throw WorkerFixtureError.invalid }
        let data = try input.read(file)
        try requireCurrent()
        return data
    }

    public func inputURL(named name: String) throws -> URL {
        try requireCurrent()
        guard let input = descriptor.inputs.first(where: { $0.name == name }) else {
            throw WorkerFixtureError.invalid
        }
        return URL(fileURLWithPath: input.path)
    }
    public func outputURL(named name: String) throws -> URL {
        try requireCurrent()
        guard let output = descriptor.outputs.first(where: { $0.name == name }) else {
            throw WorkerFixtureError.invalid
        }
        return URL(fileURLWithPath: output.path)
    }
    public func createOutputFile(named name: String) throws -> WorkerFixtureOutputFile {
        try requireCurrent()
        guard namespaceAdmissionOpen, !grantedOutputs.contains(name) else {
            throw WorkerFixtureError.invalid
        }
        guard let output = descriptor.outputs.first(where: { $0.name == name }),
            let parent = outputParents[output.parent], let scope = outputScopes[name]
        else { throw WorkerFixtureError.invalid }
        try Self.namespaceGrantsForProcess.requireAvailable([output.path: false])
        let file = try WorkerFixtureOutputFile(
            output: output, parent: parent, scope: scope,
            requireAdmission: { [self] in try requireCurrent() })
        do {
            try file.requireCurrent()
            try Self.namespaceGrantsForProcess.retain([output.path: false])
            grantedOutputs.insert(name)
            return file
        } catch {
            file.close()
            throw error
        }
    }
    public func nativeExportLease(
        stageNamed stageName: String, publicationNamed publicationName: String,
        inputsNamed inputNames: [String]
    ) throws -> WorkerFixtureNativeExportLease {
        try requireCurrent()
        guard namespaceAdmissionOpen, stageName != publicationName,
            !grantedOutputs.contains(stageName), !grantedOutputs.contains(publicationName),
            inputNames.count == 2, Set(inputNames).count == 2,
            let stage = descriptor.outputs.first(where: { $0.name == stageName }),
            let publication = descriptor.outputs.first(where: { $0.name == publicationName }),
            let stageParent = outputParents[stage.parent],
            let publicationParent = outputParents[publication.parent],
            let stageScope = outputScopes[stageName],
            let publicationScope = outputScopes[publicationName]
        else { throw WorkerFixtureError.invalid }
        try Self.namespaceGrantsForProcess.requireAvailable([
            stage.path: false, publication.path: false,
        ])
        let policy = try trust.rolePolicy(owner: descriptor.owner)
        guard let phase = WorkerFixtureFilePhase(rawValue: descriptor.phase) else {
            throw WorkerFixtureError.invalid
        }
        let resolved = try policy.resolvedOwnedPaths(
            root: trust.root, session: trust.session, phase: phase)
        let inputs = try inputNames.map { name in
            guard let input = descriptor.inputs.first(where: { $0.name == name }),
                let file = inputFiles[name],
                let scope = resolved.first(where: { $0.scope.name == name }),
                scope.scope.kind == .file, scope.scope.purpose == .immutableInput,
                scope.scope.maximumBytes == input.maximumBytes, scope.path == input.path
            else { throw WorkerFixtureError.invalid }
            let parent = try WorkerFixtureUIOpenedPath(
                URL(fileURLWithPath: input.path).deletingLastPathComponent(),
                directory: true, mode: 0o700, maximum: nil)
            _ = try input.read(file)
            return (input, file, parent)
        }
        let lease = try WorkerFixtureNativeExportLease(
            stage: stage, publication: publication,
            stageParent: stageParent, publicationParent: publicationParent,
            stageScope: stageScope, publicationScope: publicationScope,
            engine: descriptor.engine,
            requireAdmission: { [self] in
                try requireAuthorityCurrent()
                for (input, file, parent) in inputs {
                    try parent.validate()
                    _ = try input.read(file)
                }
            })
        try requireCurrent()
        try Self.namespaceGrantsForProcess.retain([stage.path: false, publication.path: false])
        grantedOutputs.formUnion([stageName, publicationName])
        nativeExports.append(lease)
        return lease
    }

    public func cooperativeNamespaceLease(
        sourceNamed sourceName: String, destinationNamed destinationName: String
    ) throws -> WorkerFixtureCooperativeNamespaceLease {
        try requireCurrent()
        guard namespaceAdmissionOpen, sourceName != destinationName,
            !grantedNamespaces.contains(sourceName), !grantedNamespaces.contains(destinationName),
            let phase = WorkerFixtureFilePhase(rawValue: descriptor.phase)
        else { throw WorkerFixtureError.invalid }
        let policy = try trust.rolePolicy(owner: descriptor.owner)
        let scopes = try policy.resolvedOwnedPaths(
            root: trust.root, session: trust.session, phase: phase)
        guard let source = scopes.first(where: { $0.scope.name == sourceName }),
            let destination = scopes.first(where: { $0.scope.name == destinationName })
        else { throw WorkerFixtureError.invalid }
        try Self.namespaceGrantsForProcess.requireAvailable([
            source.path: true, destination.path: true,
        ])
        let lease = try WorkerFixtureCooperativeNamespaceLease(
            source: source, destination: destination, engine: descriptor.engine,
            requireAdmission: { [self] in try requireAuthorityCurrent() })
        try requireCurrent()
        try Self.namespaceGrantsForProcess.retain([source.path: true, destination.path: true])
        grantedNamespaces.formUnion([sourceName, destinationName])
        namespaceGrants.append(lease)
        return lease
    }

    public func closeAdmission() {
        admissionOpen = false
        closeNamespaceAdmission()
    }

    public func closeNamespaceAdmission() {
        namespaceAdmissionOpen = false
        for lease in nativeExports { lease.closeAdmission() }
        for lease in namespaceGrants { lease.closeAdmission() }
    }

    public func waitForNamespaceCallbacks() async {
        closeAdmission()
        for lease in nativeExports { await lease.closeAndWait() }
        for lease in namespaceGrants { await lease.closeAndWait() }
        nativeExports.removeAll()
        namespaceGrants.removeAll()
    }

    public func requireInput(_ url: URL) throws {
        try requireCurrent()
        guard url.isFileURL, descriptor.inputs.contains(where: { $0.path == url.path }),
            url.path == url.standardizedFileURL.path, url.path == url.resolvingSymlinksInPath().path
        else { throw WorkerFixtureError.invalid }
    }
    public func requireOutput(_ url: URL) throws {
        try requireCurrent()
        guard url.isFileURL, descriptor.outputs.contains(where: { $0.path == url.path }),
            url.path == url.standardizedFileURL.path, url.path == url.resolvingSymlinksInPath().path
        else { throw WorkerFixtureError.invalid }
    }
    private func validateOutput(_ output: WorkerFixtureEngineOutput, initial: Bool) throws {
        guard output.path == URL(fileURLWithPath: output.path).resolvingSymlinksInPath().path,
            let parent = outputParents[output.parent], let scope = outputScopes[output.name]
        else { throw WorkerFixtureError.invalid }
        try parent.validate()
        let leaf = URL(fileURLWithPath: output.path).lastPathComponent
        guard output.path == output.parent + "/" + leaf else { throw WorkerFixtureError.invalid }
        var state = stat()
        if fstatat(parent.descriptor, leaf, &state, AT_SYMLINK_NOFOLLOW) == 0 {
            guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFREG,
                state.st_nlink == 1, state.st_mode & 0o022 == 0, state.st_size >= 0
            else { throw WorkerFixtureError.invalid }
            try scope.validate(present: true, bytes: state.st_size, initial: initial)
            let file = openat(
                parent.descriptor, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw WorkerFixtureError.invalid }
            defer { close(file) }
            var opened = stat(); var current = stat()
            guard fstat(file, &opened) == 0,
                fstatat(parent.descriptor, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
                Self.equalOutput(state, opened), Self.equalOutput(state, current)
            else { throw WorkerFixtureError.invalid }
        } else {
            guard errno == ENOENT else { throw WorkerFixtureError.invalid }
            try scope.validate(present: false, bytes: 0, initial: initial)
        }
        try parent.validate()
    }
    private static func equalOutput(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_uid == second.st_uid && first.st_mode == second.st_mode
            && first.st_nlink == second.st_nlink && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

struct WorkerFixtureEngineFactoryScope {
    let descriptor: WorkerFixtureEngineContract
    let trust: WorkerFixtureUITrust
    let owner: String
    let role: WorkerFixtureRole
    let uid: UInt32

    func perform<Value>(
        requireCurrent: () throws -> Void, factory: () throws -> Value
    ) throws -> Value {
        try descriptor.validate(trust: trust, owner: owner, uid: uid, expectedRole: role)
        try requireCurrent()
        let value = try factory()
        try requireCurrent()
        return value
    }
}

struct WorkerFixtureEngineOutputScope {
    let fileScope: WorkerFixtureFileScope?

    init(
        output: WorkerFixtureEngineOutput, policy: WorkerFixtureRolePolicy,
        root: String, session: String, phase: String
    ) throws {
        guard WorkerFixtureUIContract.canonical(root), WorkerFixtureUIContract.uuid(session),
            root.hasSuffix("/functional-fixture-" + session),
            let phase = WorkerFixtureFilePhase(rawValue: phase),
            policy.outputs.contains(output.name),
            WorkerFixtureUIContract.canonical(output.path),
            output.path == output.parent + "/"
                + URL(fileURLWithPath: output.path).lastPathComponent,
            output.parent == root + "/outputs/" + policy.owner
                || output.parent.hasPrefix(root + "/outputs/" + policy.owner + "/")
        else { throw WorkerFixtureError.invalid }
        if let named = policy.fileScopes.first(where: { $0.name == output.name }) {
            guard named.kind == .file, named.root == .ownerOutputs,
                named.purpose == .mutableState || named.purpose == .initiallyAbsentOutput,
                try named.path(owner: policy.owner, root: root, session: session, phase: phase)
                    == output.path
            else { throw WorkerFixtureError.invalid }
            fileScope = named
        } else {
            fileScope = nil
        }
    }
    func validate(present: Bool, bytes: Int64, initial: Bool) throws {
        guard bytes >= 0, present || bytes == 0 else { throw WorkerFixtureError.invalid }
        guard let fileScope else {
            guard !initial || !present else { throw WorkerFixtureError.invalid }
            return
        }
        let state: WorkerFixtureFilePresence = present ? .present : .absent
        guard fileScope.allowedStates.contains(state), bytes <= fileScope.maximumBytes,
            !initial || state == fileScope.initialState
        else { throw WorkerFixtureError.invalid }
    }
}

@MainActor public final class WorkerFixtureOutputFile {
    public let name: String
    private let output: WorkerFixtureEngineOutput
    private let parent: WorkerFixtureUIOpenedPath
    private let scope: WorkerFixtureEngineOutputScope
    private var requireAdmission: (() throws -> Void)?
    private let leaf: String
    private let original: stat
    private var file: Int32

    init(
        output: WorkerFixtureEngineOutput, parent: WorkerFixtureUIOpenedPath,
        scope: WorkerFixtureEngineOutputScope, requireAdmission: @escaping () throws -> Void
    ) throws {
        guard let policy = scope.fileScope, policy.kind == .file,
            policy.root == .ownerOutputs, policy.allowedStates.contains(.present),
            parent.url.path == output.parent,
            output.path == output.parent + "/" + URL(fileURLWithPath: output.path).lastPathComponent
        else { throw WorkerFixtureError.invalid }
        try requireAdmission()
        try parent.validate()
        var previous = stat()
        let leaf = URL(fileURLWithPath: output.path).lastPathComponent
        guard fstatat(parent.descriptor, leaf, &previous, AT_SYMLINK_NOFOLLOW) != 0,
            errno == ENOENT
        else { throw WorkerFixtureError.invalid }
        try scope.validate(present: false, bytes: 0, initial: false)
        let file = openat(
            parent.descriptor, leaf, O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_RDWR,
            mode_t(0o600))
        guard file >= 0 else { throw WorkerFixtureError.invalid }
        var state = stat()
        guard fstat(file, &state) == 0, state.st_uid == getuid(),
            state.st_mode & S_IFMT == S_IFREG, state.st_mode & 0o7777 == 0o600,
            state.st_nlink == 1, state.st_size == 0
        else { Darwin.close(file); throw WorkerFixtureError.invalid }
        name = output.name; self.output = output; self.parent = parent; self.scope = scope
        self.requireAdmission = requireAdmission; self.leaf = leaf; original = state
        self.file = file
    }

    deinit { if file >= 0 { Darwin.close(file) } }

    public func requireCurrent() throws {
        _ = try currentState()
    }

    public func read(offset: Int, count: Int) throws -> Data {
        let state = try currentState()
        guard offset >= 0, count >= 0, offset <= state.st_size,
            let maximum = scope.fileScope?.maximumBytes, count <= maximum
        else { throw WorkerFixtureError.invalid }
        let length = min(count, Int(state.st_size) - offset)
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            var completed = 0
            while completed < length {
                let amount = pread(
                    file, buffer.baseAddress!.advanced(by: completed), length - completed,
                    off_t(offset + completed))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw WorkerFixtureError.invalid }
                completed += amount
            }
        }
        let after = try currentState()
        guard Self.equalContents(state, after) else { throw WorkerFixtureError.invalid }
        return data
    }

    public func write(_ data: Data, offset: Int) throws {
        let state = try currentState()
        guard offset >= 0, offset <= state.st_size,
            let maximum = scope.fileScope?.maximumBytes,
            offset <= maximum, data.count <= maximum - offset
        else { throw WorkerFixtureError.invalid }
        try data.withUnsafeBytes { buffer in
            var completed = 0
            while completed < data.count {
                let amount = pwrite(
                    file, buffer.baseAddress!.advanced(by: completed), data.count - completed,
                    off_t(offset + completed))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw WorkerFixtureError.invalid }
                completed += amount
            }
        }
        let after = try currentState()
        guard after.st_size == max(state.st_size, Int64(offset + data.count)) else {
            throw WorkerFixtureError.invalid
        }
    }

    public func close() {
        let retired = file
        file = -1
        requireAdmission = nil
        if retired >= 0 { Darwin.close(retired) }
    }

    private func currentState() throws -> stat {
        guard file >= 0, let requireAdmission else { throw WorkerFixtureError.invalid }
        try requireAdmission()
        try parent.validate()
        var opened = stat(); var named = stat()
        guard output.path == output.parent + "/" + leaf,
            fstat(file, &opened) == 0,
            fstatat(parent.descriptor, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
            opened.st_dev == original.st_dev, opened.st_ino == original.st_ino,
            opened.st_uid == original.st_uid, opened.st_mode == original.st_mode,
            opened.st_nlink == 1, opened.st_size >= 0,
            Self.equalContents(opened, named)
        else { throw WorkerFixtureError.invalid }
        try scope.validate(present: true, bytes: opened.st_size, initial: false)
        try parent.validate()
        return opened
    }

    private static func equalContents(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_uid == second.st_uid && first.st_mode == second.st_mode
            && first.st_nlink == second.st_nlink && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

@MainActor public final class WorkerFixtureNamespaceAction {
    fileprivate let token = UUID()
    fileprivate let owner: UUID

    fileprivate init(owner: UUID) { self.owner = owner }
}

@MainActor public final class WorkerFixtureNamespaceLease {
    private let identity = UUID()
    private var requireAdmission: (() throws -> Void)?
    private var accepting = true
    private var action: WorkerFixtureNamespaceAction?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(requireAdmission: @escaping () throws -> Void) {
        self.requireAdmission = requireAdmission
    }

    public func requireCurrent() throws {
        guard accepting, let requireAdmission else { throw WorkerFixtureError.invalid }
        try requireAdmission()
    }

    public func beginAction() throws -> WorkerFixtureNamespaceAction {
        try requireCurrent()
        guard action == nil else { throw WorkerFixtureError.invalid }
        let value = WorkerFixtureNamespaceAction(owner: identity)
        action = value
        return value
    }

    public func requireCurrent(_ value: WorkerFixtureNamespaceAction) throws {
        guard value.owner == identity, action === value, let requireAdmission else {
            throw WorkerFixtureError.invalid
        }
        try requireAdmission()
    }

    public func finishAction(_ value: WorkerFixtureNamespaceAction) throws {
        guard value.owner == identity, action === value else {
            throw WorkerFixtureError.invalid
        }
        action = nil
        resumeWaitersIfClosed()
    }

    public func closeAdmission() {
        accepting = false
        resumeWaitersIfClosed()
    }

    public func closeAndWait() async {
        closeAdmission()
        guard action != nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func withAction<Value>(
        _ body: (WorkerFixtureNamespaceAction) async throws -> Value
    ) async throws -> Value {
        let value = try beginAction()
        do {
            let result = try await body(value)
            try requireCurrent(value)
            try finishAction(value)
            return result
        } catch {
            try finishAction(value)
            throw error
        }
    }

    private func resumeWaitersIfClosed() {
        guard !accepting, action == nil else { return }
        requireAdmission = nil
        let completed = waiters
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }
}

@MainActor public final class WorkerFixtureNativeExportLease {
    public let engine: WorkerFixtureUIProcess
    private let stage: WorkerFixtureEngineOutput
    private let publication: WorkerFixtureEngineOutput
    private let stageParent: WorkerFixtureUIOpenedPath
    private let publicationParent: WorkerFixtureUIOpenedPath
    private let stageScope: WorkerFixtureEngineOutputScope
    private let publicationScope: WorkerFixtureEngineOutputScope
    private let lease: WorkerFixtureNamespaceLease
    private var writeIssued = false
    private var published = false

    init(
        stage: WorkerFixtureEngineOutput, publication: WorkerFixtureEngineOutput,
        stageParent: WorkerFixtureUIOpenedPath, publicationParent: WorkerFixtureUIOpenedPath,
        stageScope: WorkerFixtureEngineOutputScope,
        publicationScope: WorkerFixtureEngineOutputScope, engine: WorkerFixtureUIProcess,
        requireAdmission: @escaping () throws -> Void
    ) throws {
        guard stage.name != publication.name, stage.path != publication.path,
            stageParent.url.path == stage.parent, publicationParent.url.path == publication.parent,
            stageScope.fileScope?.purpose == .initiallyAbsentOutput,
            publicationScope.fileScope?.purpose == .initiallyAbsentOutput,
            stageScope.fileScope?.maximumBytes == publicationScope.fileScope?.maximumBytes
        else { throw WorkerFixtureError.invalid }
        try requireAdmission()
        try stageParent.validate(); try publicationParent.validate()
        try Self.requireAbsent(stage, parent: stageParent)
        try Self.requireAbsent(publication, parent: publicationParent)
        self.stage = stage; self.publication = publication
        self.stageParent = stageParent; self.publicationParent = publicationParent
        self.stageScope = stageScope; self.publicationScope = publicationScope
        self.engine = engine
        lease = WorkerFixtureNamespaceLease(requireAdmission: requireAdmission)
    }

    public func requireCurrent(_ action: WorkerFixtureNamespaceAction) throws {
        try lease.requireCurrent(action)
        try stageParent.validate(); try publicationParent.validate()
    }

    public func stageURL(_ action: WorkerFixtureNamespaceAction) throws -> URL {
        try lease.requireCurrent(action)
        guard !writeIssued, !published else { throw WorkerFixtureError.invalid }
        try stageParent.validate(); try publicationParent.validate()
        try Self.requireAbsent(stage, parent: stageParent)
        try Self.requireAbsent(publication, parent: publicationParent)
        writeIssued = true
        return URL(fileURLWithPath: stage.path)
    }

    public func publish(_ action: WorkerFixtureNamespaceAction) throws -> URL {
        try lease.requireCurrent(action)
        guard writeIssued, !published else { throw WorkerFixtureError.invalid }
        try stageParent.validate(); try publicationParent.validate()
        try Self.requireAbsent(publication, parent: publicationParent)
        let leaf = URL(fileURLWithPath: stage.path).lastPathComponent
        let destination = URL(fileURLWithPath: publication.path).lastPathComponent
        let file = openat(
            stageParent.descriptor, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw WorkerFixtureError.invalid }
        defer { Darwin.close(file) }
        var opened = stat(); var named = stat()
        guard fstat(file, &opened) == 0,
            fstatat(stageParent.descriptor, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
            opened.st_uid == getuid(), opened.st_mode & S_IFMT == S_IFREG,
            opened.st_mode & 0o022 == 0, opened.st_nlink == 1, opened.st_size > 0,
            Self.same(opened, named)
        else { throw WorkerFixtureError.invalid }
        try stageScope.validate(present: true, bytes: opened.st_size, initial: false)
        try publicationScope.validate(present: true, bytes: opened.st_size, initial: false)
        try lease.requireCurrent(action)
        try stageParent.validate(); try publicationParent.validate()
        try Self.requireAbsent(publication, parent: publicationParent)
        guard
            renameatx_np(
                stageParent.descriptor, leaf, publicationParent.descriptor, destination,
                UInt32(RENAME_EXCL)) == 0
        else { throw WorkerFixtureError.invalid }
        published = true
        var final = stat(); var retained = stat()
        guard fstat(file, &retained) == 0,
            fstatat(publicationParent.descriptor, destination, &final, AT_SYMLINK_NOFOLLOW) == 0,
            retained.st_dev == opened.st_dev, retained.st_ino == opened.st_ino,
            retained.st_size == opened.st_size, Self.same(retained, final)
        else { throw WorkerFixtureError.invalid }
        try stageParent.validate(); try publicationParent.validate()
        try lease.requireCurrent(action)
        return URL(fileURLWithPath: publication.path)
    }

    public func withAction<Value>(
        _ body: (WorkerFixtureNamespaceAction) async throws -> Value
    ) async throws -> Value {
        try await lease.withAction(body)
    }

    public func closeAdmission() { lease.closeAdmission() }
    public func closeAndWait() async { await lease.closeAndWait() }

    private static func requireAbsent(
        _ output: WorkerFixtureEngineOutput, parent: WorkerFixtureUIOpenedPath
    ) throws {
        let leaf = URL(fileURLWithPath: output.path).lastPathComponent
        guard output.path == parent.url.path + "/" + leaf else {
            throw WorkerFixtureError.invalid
        }
        var state = stat()
        guard fstatat(parent.descriptor, leaf, &state, AT_SYMLINK_NOFOLLOW) != 0,
            errno == ENOENT
        else { throw WorkerFixtureError.invalid }
    }

    private static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_uid == second.st_uid && first.st_mode == second.st_mode
            && first.st_nlink == second.st_nlink && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

@MainActor public final class WorkerFixtureCooperativeNamespaceLease {
    public let engine: WorkerFixtureUIProcess
    private let source: WorkerFixtureUIOpenedPath
    private let destination: WorkerFixtureUIOpenedPath
    private let parents: [WorkerFixtureUIOpenedPath]
    private let inputs: [String: WorkerFixtureUIOpenedPath]
    private let hashes: [String: String]
    private let lease: WorkerFixtureNamespaceLease
    private var moved: Set<String> = []

    init(
        source: WorkerFixtureResolvedFileScope, destination: WorkerFixtureResolvedFileScope,
        engine: WorkerFixtureUIProcess, requireAdmission: @escaping () throws -> Void
    ) throws {
        guard source.scope.kind == .directory, destination.scope.kind == .directory,
            source.scope.purpose == .mutableState, destination.scope.purpose == .mutableState,
            destination.scope.root == .ownerOutputs,
            source.path != destination.path,
            !source.path.hasPrefix(destination.path + "/"),
            !destination.path.hasPrefix(source.path + "/"),
            source.scope.mutableFiles.count == 2, destination.scope.mutableFiles.count == 2,
            source.scope.mutableFiles.allSatisfy({
                $0.components.count == 1 && $0.initialState == .present
                    && Set($0.allowedStates) == [.present, .absent]
            }),
            destination.scope.mutableFiles.allSatisfy({
                $0.components.count == 1 && $0.initialState == .absent
                    && Set($0.allowedStates) == [.present, .absent]
            })
        else { throw WorkerFixtureError.invalid }
        try requireAdmission()
        let sourceURL = URL(fileURLWithPath: source.path, isDirectory: true)
        let destinationURL = URL(fileURLWithPath: destination.path, isDirectory: true)
        parents = try [sourceURL, destinationURL].map {
            try WorkerFixtureUIOpenedPath(
                $0.deletingLastPathComponent(), directory: true, mode: 0o700, maximum: nil)
        }
        self.source = try WorkerFixtureUIOpenedPath(
            sourceURL, directory: true, mode: 0o700, maximum: nil)
        self.destination = try WorkerFixtureUIOpenedPath(
            destinationURL, directory: true, mode: 0o700, maximum: nil)
        var files: [String: WorkerFixtureUIOpenedPath] = [:]
        var digests: [String: String] = [:]
        for input in source.scope.mutableFiles {
            guard
                let target = destination.scope.mutableFiles.first(where: {
                    $0.components == input.components
                }), target.maximumBytes == input.maximumBytes
            else { throw WorkerFixtureError.invalid }
            let leaf = input.components[0]
            let file = try WorkerFixtureUIOpenedPath(
                sourceURL.appendingPathComponent(leaf), directory: false,
                mode: 0o600, maximum: input.maximumBytes)
            files[leaf] = file
            digests[leaf] = WorkerFixtureUIAdmission.digest(try file.read())
        }
        inputs = files; hashes = digests; self.engine = engine
        lease = WorkerFixtureNamespaceLease(requireAdmission: requireAdmission)
        try validateNamespace()
        try requireAdmission()
    }

    public func requireCurrent(_ action: WorkerFixtureNamespaceAction) throws {
        try lease.requireCurrent(action)
        try validateNamespace()
    }

    public func moveToPrivateTrash(
        _ url: URL, action: WorkerFixtureNamespaceAction
    ) throws -> URL {
        try lease.requireCurrent(action)
        try validateNamespace()
        let leaf = url.lastPathComponent
        guard url.isFileURL, url.path == source.url.path + "/" + leaf,
            inputs[leaf] != nil, !moved.contains(leaf)
        else { throw WorkerFixtureError.invalid }
        guard
            renameatx_np(
                source.descriptor, leaf, destination.descriptor, leaf, UInt32(RENAME_EXCL)) == 0
        else { throw WorkerFixtureError.invalid }
        moved.insert(leaf)
        try validateNamespace()
        try lease.requireCurrent(action)
        return destination.url.appendingPathComponent(leaf)
    }

    public func withAction<Value>(
        _ body: (WorkerFixtureNamespaceAction) async throws -> Value
    ) async throws -> Value {
        try await lease.withAction { action in
            try validateNamespace()
            let value = try await body(action)
            try validateNamespace()
            return value
        }
    }

    public func closeAdmission() { lease.closeAdmission() }
    public func closeAndWait() async { await lease.closeAndWait() }

    private func validateNamespace() throws {
        try parents.forEach { try $0.validate() }
        try source.validate(); try destination.validate()
        let sourceLeaves = try FileManager.default.contentsOfDirectory(atPath: source.url.path)
        let destinationLeaves = try FileManager.default.contentsOfDirectory(
            atPath: destination.url.path)
        guard Set(sourceLeaves) == Set(inputs.keys).subtracting(moved),
            Set(destinationLeaves) == moved
        else { throw WorkerFixtureError.invalid }
        for (leaf, file) in inputs {
            var retained = stat(); var named = stat()
            let parent = moved.contains(leaf) ? destination : source
            guard fstat(file.descriptor, &retained) == 0,
                fstatat(parent.descriptor, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                retained.st_dev == file.original.st_dev, retained.st_ino == file.original.st_ino,
                retained.st_mode == file.original.st_mode, retained.st_uid == file.original.st_uid,
                retained.st_size == file.original.st_size, retained.st_nlink == 1,
                named.st_dev == retained.st_dev, named.st_ino == retained.st_ino,
                named.st_mode == retained.st_mode, named.st_uid == retained.st_uid,
                named.st_size == retained.st_size, named.st_nlink == 1
            else { throw WorkerFixtureError.invalid }
            if !moved.contains(leaf) { try file.validate() }
            var bytes = Data(count: Int(retained.st_size))
            let count = bytes.withUnsafeMutableBytes {
                pread(file.descriptor, $0.baseAddress, $0.count, 0)
            }
            guard count == bytes.count, WorkerFixtureUIAdmission.digest(bytes) == hashes[leaf]
            else { throw WorkerFixtureError.invalid }
        }
        try parents.forEach { try $0.validate() }
        try source.validate(); try destination.validate()
    }
}

@MainActor final class WorkerFixtureNamespaceGrantBook {
    private var retained: [String: Bool] = [:]

    func requireAvailable(_ claims: [String: Bool]) throws {
        guard !claims.isEmpty, claims.keys.allSatisfy(WorkerFixtureUIContract.canonical) else {
            throw WorkerFixtureError.invalid
        }
        let existing = retained.merging(claims) { _, new in new }
        guard existing.count == retained.count + claims.count else {
            throw WorkerFixtureError.invalid
        }
        let all = Array(existing)
        for first in all {
            for second in all where first.key != second.key {
                let path = first.key.lowercased(); let other = second.key.lowercased()
                guard path != other, !first.value || !other.hasPrefix(path + "/") else {
                    throw WorkerFixtureError.invalid
                }
            }
        }
    }

    func retain(_ claims: [String: Bool]) throws {
        try requireAvailable(claims)
        retained.merge(claims) { _, new in new }
    }
}
