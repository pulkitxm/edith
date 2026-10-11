import Darwin
import Foundation

@MainActor public final class WorkerFixtureBootstrapAdmission {
    public let contract: WorkerFixtureBootstrapContract
    public var contextMarker: [String: String] { contract.contextMarker }
    private let trust: WorkerFixtureBootstrapTrust
    private let paths: [WorkerFixtureUIOpenedPath]
    private let host: URL
    private let worker: URL
    private let role: URL
    private let owner: String
    private let expectedRole: WorkerFixtureRole

    private init(
        contract: WorkerFixtureBootstrapContract, trust: WorkerFixtureBootstrapTrust,
        paths: [WorkerFixtureUIOpenedPath], host: URL, worker: URL, role: URL,
        owner: String, expectedRole: WorkerFixtureRole
    ) {
        self.contract = contract; self.trust = trust; self.paths = paths
        self.host = host; self.worker = worker; self.role = role
        self.owner = owner; self.expectedRole = expectedRole
    }

    public static func current(
        extensionID: String, context: NSDictionary, roleURL: URL,
        expectedRole: WorkerFixtureRole = .app, purpose: WorkerFixtureBootstrapPurpose,
        workerBundle: Bundle = .main
    ) throws -> WorkerFixtureBootstrapAdmission? {
        let environment = ProcessInfo.processInfo.environment
        let intent =
            context["hostedFunctionalFixture"] != nil
            || environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            || (context["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.") == true
            || workerBundle.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
            || environment["EDITH_APPLICATION_IDENTIFIER"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || environment["EDITH_SHARED_DEFAULTS_SUITE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
        guard intent else { return nil }
        guard let trust = WorkerFixtureBootstrapTrustAnchor.admitted else {
            throw WorkerFixtureError.invalid
        }
        try trust.validate()
        try WorkerFixtureBootstrapContract.validateContext(
            context, environment: environment, purpose: purpose, trust: trust,
            owner: extensionID, expectedRole: expectedRole,
            workerIdentifier: workerBundle.bundleIdentifier ?? "")
        guard
            let version = workerBundle.object(forInfoDictionaryKey: "EdithExtensionVersion")
                as? String,
            WorkerFixtureUIContract.version(version),
            workerBundle.bundleURL.path == trust.root + "/Extensions/" + extensionID
                + "/edith-host-2/arm64/" + version + "/" + extensionID
                + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex",
            roleURL.isFileURL,
            roleURL.path == workerBundle.bundleURL.path
                + "/Contents/Resources/Payload/" + extensionID + "/" + expectedRole.rawValue
                + ".bundle"
        else { throw WorkerFixtureError.invalid }
        let documentPath =
            trust.root + (purpose == .engine ? "/functional-engine-" : "/functional-ui-")
            + extensionID + ".json"
        let root = URL(fileURLWithPath: trust.root, isDirectory: true)
        var paths = [
            try WorkerFixtureUIOpenedPath(root, directory: true, mode: 0o700, maximum: nil)
        ]
        let document = try WorkerFixtureUIOpenedPath(
            URL(fileURLWithPath: documentPath), directory: false, mode: 0o600, maximum: 131_072)
        paths.append(document)
        let contract = try WorkerFixtureBootstrapContract.verify(
            document.read(), purpose: purpose, trust: trust, owner: extensionID,
            expectedRole: expectedRole, uid: getuid())
        guard contract.workerPath == workerBundle.bundleURL.path, contract.rolePath == roleURL.path,
            contract.version == version, contract.currentProcess.pid == getpid(),
            contract.currentProcess.executable == workerBundle.executableURL?.path
        else { throw WorkerFixtureError.invalid }
        if let marker = context["hostedFunctionalFixture"] {
            guard let marker = marker as? NSDictionary else { throw WorkerFixtureError.invalid }
            try contract.validateMarker(marker)
        }
        if case .ui(let value) = contract {
            guard (context["presentationID"] as? String)?.lowercased() == value.presentationID,
                context["location"] as? String == value.location,
                context["section"] as? String == value.section
            else { throw WorkerFixtureError.invalid }
        }
        let host = root.appendingPathComponent("Fixture.app", isDirectory: true)
        for directory in [
            root.appendingPathComponent(extensionID + "-home"),
            root.appendingPathComponent("data/" + extensionID),
        ] {
            paths.append(
                try WorkerFixtureUIOpenedPath(directory, directory: true, mode: 0o700, maximum: nil)
            )
        }
        for bundle in [host, workerBundle.bundleURL, roleURL] {
            paths.append(
                try WorkerFixtureUIOpenedPath(bundle, directory: true, mode: nil, maximum: nil))
            paths.append(
                try WorkerFixtureUIOpenedPath(
                    bundle.appendingPathComponent("Contents/Info.plist"), directory: false,
                    mode: nil, maximum: 131_072))
        }
        if case .engine(let value) = contract {
            for input in value.inputs {
                let file = try WorkerFixtureUIOpenedPath(
                    URL(fileURLWithPath: input.path), directory: false, mode: nil,
                    maximum: input.maximumBytes)
                guard WorkerFixtureUIAdmission.digest(try file.read()) == input.sha256 else {
                    throw WorkerFixtureError.invalid
                }
                paths.append(file)
            }
            for parent in Set(value.outputs.map(\.parent)) {
                paths.append(
                    try WorkerFixtureUIOpenedPath(
                        URL(fileURLWithPath: parent), directory: true, mode: 0o700, maximum: nil))
            }
            for output in value.outputs {
                var state = stat()
                guard lstat(output.path, &state) == -1, errno == ENOENT else {
                    throw WorkerFixtureError.invalid
                }
            }
        }
        let admission = WorkerFixtureBootstrapAdmission(
            contract: contract, trust: trust, paths: paths, host: host,
            worker: workerBundle.bundleURL,
            role: roleURL, owner: extensionID, expectedRole: expectedRole)
        try admission.requireCurrent()
        guard let hostBundle = Bundle(url: host), let roleBundle = Bundle(url: roleURL),
            hostBundle.bundleIdentifier == trust.hostIdentifier,
            hostBundle.object(forInfoDictionaryKey: "EdithHostedFunctionalSession") as? String
                == trust.session,
            hostBundle.object(forInfoDictionaryKey: "EdithHostedFunctionalSourceCommit") as? String
                == trust.sourceCommit,
            roleBundle.bundleIdentifier == "com.pulkit.edith.extensions." + extensionID + "."
                + expectedRole.rawValue,
            roleBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == version,
            roleBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == "edith-host-2",
            workerBundle.object(forInfoDictionaryKey: "EdithExtensionID") as? String == extensionID,
            workerBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == "edith-host-2",
            workerBundle.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String
                == trust.hostIdentifier,
            workerBundle.object(forInfoDictionaryKey: "EdithHostExecutablePath") as? String
                == host.appendingPathComponent("Contents/MacOS/Edith").path
        else { throw WorkerFixtureError.invalid }
        try admission.requireCurrent()
        return admission
    }

    public func requireCurrent() throws {
        try trust.validate()
        try paths.forEach { try $0.validate() }
        guard try WorkerFixtureUIAdmission.observe(contract.producer) == contract.producer,
            try WorkerFixtureUIAdmission.observe(contract.engine) == contract.engine,
            try WorkerFixtureUIAdmission.observe(contract.currentProcess)
                == contract.currentProcess,
            try WorkerFixtureUIAdmission.verifySignature(
                host, identifier: trust.hostIdentifier, requirement: trust.hostRequirement)
                == trust.hostCertificateSHA256,
            try WorkerFixtureUIAdmission.verifySignature(
                worker, identifier: trust.hostIdentifier + ".extension." + owner + ".worker",
                requirement: nil) == trust.workerCertificateSHA256,
            try WorkerFixtureUIAdmission.verifySignature(
                role,
                identifier: "com.pulkit.edith.extensions." + owner + "." + expectedRole.rawValue,
                requirement: nil) == trust.roleCertificateSHA256
        else { throw WorkerFixtureError.invalid }
        try paths.forEach { try $0.validate() }
    }
}
