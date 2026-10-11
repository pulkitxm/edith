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

    #if EDITH_FUNCTIONAL_FIXTURE
    var platformRole: WorkerFixtureRole { expectedRole }

    public func withPlatformFixture<Value>(
        extensionID: String, expectedRole: WorkerFixtureRole,
        _ factory: (WorkerFixtureAdmission) throws -> Value
    ) throws -> Value {
        let scope = WorkerFixtureEngineFactoryScope(
            descriptor: descriptor, trust: trust, owner: extensionID, role: expectedRole,
            uid: getuid())
        return try scope.perform(requireCurrent: requireCurrent) {
            try factory(WorkerFixtureAdmission.retaining(self))
        }
    }
    #endif

    public func requireCurrent() throws {
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
        try requireCurrent()
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
