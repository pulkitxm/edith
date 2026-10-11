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

    private init(
        descriptor: WorkerFixtureEngineContract, trust: WorkerFixtureUITrust,
        paths: [WorkerFixtureUIOpenedPath], host: URL, worker: URL, role: URL,
        expectedRole: WorkerFixtureRole, inputFiles: [String: WorkerFixtureUIOpenedPath]
    ) {
        self.descriptor = descriptor; self.trust = trust; self.paths = paths
        self.host = host; self.worker = worker; self.role = role; self.expectedRole = expectedRole
        self.inputFiles = inputFiles
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
        for parent in Set(descriptor.outputs.map(\.parent)) {
            paths.append(
                try WorkerFixtureUIOpenedPath(
                    URL(fileURLWithPath: parent), directory: true, mode: 0o700, maximum: nil))
        }
        for output in descriptor.outputs {
            var state = stat()
            guard lstat(output.path, &state) == -1, errno == ENOENT else {
                throw WorkerFixtureError.invalid
            }
        }
        let admission = WorkerFixtureEngineAdmission(
            descriptor: descriptor, trust: trust, paths: paths,
            host: host, worker: workerBundle.bundleURL, role: roleBundle.bundleURL,
            expectedRole: expectedRole, inputFiles: inputFiles)
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
        for output in descriptor.outputs { try validateOutput(output.path) }
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
    private func validateOutput(_ path: String) throws {
        guard path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else {
            throw WorkerFixtureError.invalid
        }
        var state = stat()
        if lstat(path, &state) == 0 {
            guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFREG,
                state.st_nlink == 1, state.st_mode & 0o022 == 0
            else { throw WorkerFixtureError.invalid }
        } else if errno != ENOENT {
            throw WorkerFixtureError.invalid
        }
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
