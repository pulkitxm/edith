import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

@MainActor
public final class WorkerFixtureUIAdmission {
    public let descriptor: WorkerFixtureUIContract
    private let paths: [WorkerFixtureUIOpenedPath]
    private let producer: WorkerFixtureUIProcess
    private let trust: WorkerFixtureUITrust
    private let host: URL
    private let worker: URL
    private let role: URL

    private init(
        descriptor: WorkerFixtureUIContract, paths: [WorkerFixtureUIOpenedPath],
        producer: WorkerFixtureUIProcess, trust: WorkerFixtureUITrust,
        host: URL, worker: URL, role: URL
    ) {
        self.descriptor = descriptor
        self.paths = paths
        self.producer = producer
        self.trust = trust
        self.host = host
        self.worker = worker
        self.role = role
    }

    public static func current(
        extensionID: String, context: NSDictionary, roleBundle: Bundle, workerBundle: Bundle = .main
    ) throws -> WorkerFixtureUIAdmission? {
        let environment = ProcessInfo.processInfo.environment
        let suppliedHost = context["hostIdentifier"] as? String
        let intent =
            suppliedHost?.hasPrefix("com.pulkit.edith.tests.") == true
            || workerBundle.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
            || environment["EDITH_APPLICATION_IDENTIFIER"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || environment["EDITH_SHARED_DEFAULTS_SUITE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || context["hostedFunctionalFixture"] != nil
            || environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        guard intent else { return nil }
        let roleKind: WorkerFixtureRole
        if roleBundle.bundleIdentifier == "com.pulkit.edith.extensions." + extensionID + ".app" {
            roleKind = .app
        } else if roleBundle.bundleIdentifier == "com.pulkit.edith.extensions." + extensionID
            + ".helper",
            WorkerFixtureUIContract.helperOwners.contains(extensionID)
        {
            roleKind = .helper
        } else {
            throw WorkerFixtureError.invalid
        }
        let usesSettingsService =
            roleKind == .helper && extensionID == "notchShelf"
            && (context["uiOnly"] as? NSNumber)?.boolValue == false
        guard let trust = WorkerFixtureUITrustAnchor.admitted,
            WorkerFixtureUIContract.owners.contains(extensionID),
            let hostIdentifier = suppliedHost,
            hostIdentifier.hasPrefix("com.pulkit.edith.tests.worker-"),
            let remote = context["remoteUI"] as? NSNumber,
            CFGetTypeID(remote) == CFBooleanGetTypeID(), remote.boolValue,
            let only = context["uiOnly"] as? NSNumber,
            CFGetTypeID(only) == CFBooleanGetTypeID(),
            only.boolValue == (roleKind == .helper && !usesSettingsService),
            context["extensionID"] as? String == extensionID,
            let location = context["location"] as? String,
            let section = context["section"] as? String,
            let presentation = context["presentationID"] as? String,
            WorkerFixtureUIContract.uuid(presentation.lowercased()),
            let marker = context["hostedFunctionalFixture"] as? [String: String],
            Set(marker.keys) == [
                "sourceCommit", "session", "phase", "descriptorPath", "capabilitySHA256",
            ],
            marker["sourceCommit"] == trust.sourceCommit,
            marker["session"] == trust.session,
            let phase = marker["phase"],
            let capabilitySHA256 = marker["capabilitySHA256"],
            marker["descriptorPath"] == trust.root + "/functional-ui-" + extensionID + ".json",
            (roleKind == .helper && !usesSettingsService)
                || Self.validEngineClient(context["engineClient"]),
            workerBundle.bundleIdentifier == hostIdentifier + ".extension." + extensionID
                + ".worker",
            context["defaultsSuite"] as? String == workerBundle.bundleIdentifier,
            environment["EDITH_APPLICATION_IDENTIFIER"] == hostIdentifier,
            environment["EDITH_EXTENSION_ID"] == extensionID,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == workerBundle.bundleIdentifier,
            workerBundle.bundleURL.pathExtension == "appex",
            roleBundle.bundleIdentifier == "com.pulkit.edith.extensions." + extensionID + "."
                + roleKind.rawValue,
            let version = roleBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            roleBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == "edith-host-2",
            workerBundle.object(forInfoDictionaryKey: "EdithExtensionID") as? String == extensionID,
            workerBundle.object(forInfoDictionaryKey: "EdithExtensionVersion") as? String
                == version,
            workerBundle.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String
                == hostIdentifier,
            workerBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == "edith-host-2",
            let executable = workerBundle.object(forInfoDictionaryKey: "EdithHostExecutablePath")
                as? String,
            executable.hasSuffix("/Fixture.app/Contents/MacOS/Edith"),
            let dataDirectory = context["dataDirectory"] as? String
        else { throw WorkerFixtureError.invalid }
        let host = URL(fileURLWithPath: executable).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = host.deletingLastPathComponent()
        let session = String(hostIdentifier.dropFirst("com.pulkit.edith.tests.worker-".count))
        guard WorkerFixtureUIContract.uuid(session),
            root.path.hasSuffix("/functional-fixture-" + session)
        else { throw WorkerFixtureError.invalid }
        try trust.validate()
        guard root.path == trust.root, session == trust.session,
            hostIdentifier == trust.hostIdentifier,
            dataDirectory == trust.root + "/data/" + extensionID,
            workerBundle.bundleURL.path == trust.root + "/Extensions/" + extensionID
                + "/edith-host-2/arm64/" + version + "/" + extensionID
                + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex",
            roleBundle.bundleURL.path == workerBundle.bundleURL.path
                + "/Contents/Resources/Payload/" + extensionID + "/" + roleKind.rawValue
                + ".bundle",
            let hostBundle = Bundle(url: host)
        else { throw WorkerFixtureError.invalid }
        var paths: [WorkerFixtureUIOpenedPath] = []
        for url in [
            root, root.appendingPathComponent(extensionID + "-home"),
            URL(fileURLWithPath: dataDirectory),
        ] {
            paths.append(
                try WorkerFixtureUIOpenedPath(url, directory: true, mode: 0o700, maximum: nil))
        }
        for bundle in [host, workerBundle.bundleURL, roleBundle.bundleURL] {
            paths.append(
                try WorkerFixtureUIOpenedPath(bundle, directory: true, mode: nil, maximum: nil))
            paths.append(
                try WorkerFixtureUIOpenedPath(
                    bundle.appendingPathComponent("Contents/Info.plist"), directory: false,
                    mode: nil, maximum: 131_072))
        }
        let hostExecutable = try WorkerFixtureUIOpenedPath(
            host.appendingPathComponent("Contents/MacOS/Edith"), directory: false,
            mode: nil, maximum: 268_435_456)
        paths.append(hostExecutable)
        try trust.validate()
        guard Self.digest(try hostExecutable.read()) == trust.hostExecutableSHA256,
            hostIdentifier == trust.hostIdentifier, session == trust.session,
            root.path == trust.root,
            try verifySignature(
                host, identifier: hostIdentifier, requirement: trust.hostRequirement)
                == trust.hostCertificateSHA256,
            try verifySignature(
                workerBundle.bundleURL, identifier: workerBundle.bundleIdentifier!, requirement: nil
            )
                == trust.workerCertificateSHA256,
            try verifySignature(
                roleBundle.bundleURL, identifier: roleBundle.bundleIdentifier!, requirement: nil)
                == trust.roleCertificateSHA256,
            hostBundle.object(forInfoDictionaryKey: "EdithHostedFunctionalSession") as? String
                == trust.session,
            hostBundle.object(forInfoDictionaryKey: "EdithHostedFunctionalSourceCommit") as? String
                == trust.sourceCommit
        else { throw WorkerFixtureError.invalid }
        let document = try WorkerFixtureUIOpenedPath(
            root.appendingPathComponent("functional-ui-" + extensionID + ".json"), directory: false,
            mode: 0o600, maximum: 131_072)
        paths.append(document)
        let descriptor = try WorkerFixtureUIContract.verify(
            document.read(), issuerKey: trust.issuerKey)
        guard descriptor.producer.executable == trust.producerExecutable,
            descriptor.producer.executableSHA256 == trust.producerExecutableSHA256
        else { throw WorkerFixtureError.invalid }
        var settingsService: WorkerFixtureEngineContract?
        if usesSettingsService {
            let engineDocument = try WorkerFixtureUIOpenedPath(
                root.appendingPathComponent("functional-engine-notchShelf.json"), directory: false,
                mode: 0o600, maximum: 131_072)
            paths.append(engineDocument)
            let service = try WorkerFixtureEngineContract.verify(
                engineDocument.read(), issuerKey: trust.issuerKey)
            try service.validate(
                trust: trust, owner: "notchShelf", uid: getuid(), expectedRole: .helper)
            try descriptor.validateSettingsService(service)
            settingsService = service
        }
        try WorkerFixtureUIContract.validateUIContext(
            context, environment: environment, owner: extensionID,
            workerIdentifier: workerBundle.bundleIdentifier ?? "", role: roleKind,
            settingsService: settingsService)
        let producer = descriptor.producer
        let observedProducer = try observe(producer)
        let engine = try observe(descriptor.engine)
        let ui = try observe(descriptor.ui)
        guard ui.pid == getpid(), ui.executable == workerBundle.executableURL?.path,
            environment["HOME"] == descriptor.home,
            environment["CFFIXED_USER_HOME"] == descriptor.home,
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == descriptor.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == descriptor.dataDirectory
        else { throw WorkerFixtureError.invalid }
        try descriptor.validate(
            sourceCommit: trust.sourceCommit, session: session, owner: extensionID,
            presentationID: presentation.lowercased(), phase: phase,
            location: location, section: section, capabilitySHA256: capabilitySHA256,
            root: root.path, dataDirectory: dataDirectory,
            workerPath: workerBundle.bundleURL.path, rolePath: roleBundle.bundleURL.path,
            version: version, uid: getuid(), producer: observedProducer, engine: engine, ui: ui)
        let result = WorkerFixtureUIAdmission(
            descriptor: descriptor, paths: paths, producer: producer,
            trust: trust, host: host,
            worker: workerBundle.bundleURL, role: roleBundle.bundleURL)
        try result.requireCurrent()
        return result
    }

    public func requireCurrent() throws {
        try trust.validate()
        try paths.forEach { try $0.validate() }
        let executable = try WorkerFixtureUIOpenedPath(
            host.appendingPathComponent("Contents/MacOS/Edith"), directory: false,
            mode: nil, maximum: 268_435_456)
        guard Self.digest(try executable.read()) == trust.hostExecutableSHA256,
            try Self.observe(producer) == producer,
            try Self.observe(descriptor.engine) == descriptor.engine,
            try Self.observe(descriptor.ui) == descriptor.ui,
            try Self.verifySignature(
                host, identifier: descriptor.hostIdentifier, requirement: trust.hostRequirement)
                == trust.hostCertificateSHA256,
            try Self.verifySignature(
                worker,
                identifier: descriptor.hostIdentifier + ".extension." + descriptor.owner
                    + ".worker", requirement: nil) == trust.workerCertificateSHA256,
            try Self.verifySignature(
                role,
                identifier: "com.pulkit.edith.extensions." + descriptor.owner + "."
                    + role.lastPathComponent.replacingOccurrences(of: ".bundle", with: ""),
                requirement: nil) == trust.roleCertificateSHA256
        else { throw WorkerFixtureError.invalid }
        try paths.forEach { try $0.validate() }
    }

    static func validEngineClient(_ value: Any?) -> Bool {
        guard let client = value as? NSObject else { return false }
        return client.responds(to: NSSelectorFromString("invoke:completion:"))
            && client.responds(to: NSSelectorFromString("cancel:"))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func observe(_ expected: WorkerFixtureUIProcess) throws -> WorkerFixtureUIProcess {
        try expected.validate(uid: getuid())
        var first = proc_bsdinfo(); var last = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &first, size) == size,
            first.pbi_uid == getuid(), first.pbi_ruid == getuid(), first.pbi_status != SZOMB,
            first.pbi_start_tvusec < 1_000_000,
            proc_pidpath(expected.pid, &path, UInt32(path.count)) > 0,
            let end = path.firstIndex(of: 0)
        else { throw WorkerFixtureError.invalid }
        let executable = String(decoding: path[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard executable == expected.executable else { throw WorkerFixtureError.invalid }
        let file = try WorkerFixtureUIOpenedPath(
            URL(fileURLWithPath: executable), directory: false, mode: nil, maximum: 268_435_456,
            allowsRootOwner: true)
        let digest = SHA256.hash(data: try file.read()).map { String(format: "%02x", $0) }.joined()
        guard proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &last, size) == size,
            first.pbi_uid == last.pbi_uid, first.pbi_ruid == last.pbi_ruid,
            first.pbi_start_tvsec == last.pbi_start_tvsec,
            first.pbi_start_tvusec == last.pbi_start_tvusec, last.pbi_status != SZOMB
        else { throw WorkerFixtureError.invalid }
        let result = WorkerFixtureUIProcess(
            pid: expected.pid, birthSeconds: first.pbi_start_tvsec,
            birthMicroseconds: UInt32(first.pbi_start_tvusec), uid: first.pbi_uid,
            executable: executable,
            executableSHA256: digest)
        guard result == expected else { throw WorkerFixtureError.invalid }
        return result
    }

    static func verifySignature(
        _ url: URL, identifier: String, requirement expression: String?
    ) throws -> Data {
        var code: SecStaticCode?; var requirement: SecRequirement?
        if let expression {
            guard
                SecRequirementCreateWithString(expression as CFString, [], &requirement)
                    == errSecSuccess
            else { throw WorkerFixtureError.invalid }
        }
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(
                    rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode
                        | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { throw WorkerFixtureError.invalid }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == identifier,
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { throw WorkerFixtureError.invalid }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }
}

final class WorkerFixtureUIOpenedPath {
    let url: URL
    let descriptor: Int32
    let original: stat

    init(_ url: URL, directory: Bool, mode: mode_t?, maximum: Int?, allowsRootOwner: Bool = false)
        throws
    {
        guard url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path
        else { throw WorkerFixtureError.invalid }
        let descriptor = open(
            url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
        )
        guard descriptor >= 0 else { throw WorkerFixtureError.invalid }
        var state = stat()
        guard fstat(descriptor, &state) == 0,
            state.st_uid == getuid() || (allowsRootOwner && state.st_uid == 0),
            state.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), state.st_mode & 0o022 == 0,
            mode.map({ state.st_mode & 0o7777 == $0 }) ?? true,
            directory
                || (state.st_nlink == 1 && state.st_size > 0 && state.st_size <= (maximum ?? 0))
        else { close(descriptor); throw WorkerFixtureError.invalid }
        self.url = url; self.descriptor = descriptor; original = state
    }
    deinit { close(descriptor) }
    func read() throws -> Data {
        var bytes = Data(count: Int(original.st_size))
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == bytes.count else { throw WorkerFixtureError.invalid }
        try validate()
        return bytes
    }
    func validate() throws {
        var opened = stat(); var current = stat()
        guard url.path == url.resolvingSymlinksInPath().path, fstat(descriptor, &opened) == 0,
            lstat(url.path, &current) == 0, Self.equal(original, opened),
            Self.equal(original, current)
        else { throw WorkerFixtureError.invalid }
    }
    private static func equal(_ first: stat, _ second: stat) -> Bool {
        guard first.st_dev == second.st_dev, first.st_ino == second.st_ino,
            first.st_uid == second.st_uid,
            first.st_mode == second.st_mode
        else { return false }
        return first.st_mode & S_IFMT == S_IFDIR
            || (first.st_nlink == second.st_nlink && first.st_size == second.st_size
                && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
                && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
                && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
                && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec)
    }
}
