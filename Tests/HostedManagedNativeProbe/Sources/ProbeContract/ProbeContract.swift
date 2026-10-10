import Darwin
import Foundation

public enum ProbeContractError: Error, Equatable {
    case untrustedRunner
    case invalidIdentity
    case invalidFixture
    case invalidFixtureField(String)
    case ambiguousControl
    case unsupportedControl
    case incompleteProof
}

public enum ProbeRunner {
    public static func accountHome() throws -> URL {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home = try buffer.withUnsafeMutableBufferPointer {
            let status = getpwuid_r(getuid(), &record, $0.baseAddress, $0.count, &result)
            guard status == 0, result != nil, record.pw_uid == getuid(), let path = record.pw_dir
            else {
                throw ProbeContractError.invalidFixtureField("accountHome")
            }
            return String(cString: path)
        }
        guard home.hasPrefix("/"), home.utf8.count <= 4096,
            URL(fileURLWithPath: home).standardizedFileURL.path == home
        else { throw ProbeContractError.invalidFixtureField("accountHome") }
        return URL(fileURLWithPath: home)
    }
}

public struct ProbeFixture: Codable, Sendable {
    public let directory: String
    public let app: String
    public let executable: String
    public let carrier: String
    public let worker: String
    public let identifier: String
    public let extensionID: String
    public let version: String
    public let hostABI: String
    public let hostExecutableSHA256: String
    public let backgroundOnly: Bool

    public var workerIdentifier: String { "\(identifier).extension.calendar.worker" }

    public func validateRegisteredApplications(_ urls: [URL]) throws {
        guard urls.count == 1, urls[0].path == app,
            urls[0].resolvingSymlinksInPath().path == app
        else { throw ProbeContractError.invalidFixtureField("ambiguousRegisteredApplication") }
    }

    public func validateApplicationInfo(_ data: Data) throws {
        guard data.count <= 16_384,
            let info = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            info["CFBundleIdentifier"] as? String == identifier,
            info["CFBundleExecutable"] as? String == "Edith",
            info["CFBundlePackageType"] as? String == "APPL"
        else { throw ProbeContractError.invalidFixtureField("applicationInfo") }
    }

    public func validate(home: URL, environment: [String: String]) throws {
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_OS"] == "macOS",
            environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["EDITH_HOSTED_MANAGED_PROBE"] == "1"
        else { throw ProbeContractError.untrustedRunner }
        let suffix = String(identifier.dropFirst("com.pulkit.edith.tests.remote-".count))
        guard identifier == "com.pulkit.edith.tests.remote-\(suffix)",
            UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
        else { throw ProbeContractError.invalidIdentity }
        let base = home.appendingPathComponent("Applications").path + "/Edith Remote Fixture "
        guard directory.hasPrefix(base), directory.count > base.count else {
            throw ProbeContractError.invalidFixtureField("directoryOutsideAccountHome")
        }
        guard extensionID == "calendar", backgroundOnly,
            version.range(of: #"^\d{1,8}\.\d{1,8}\.\d{1,8}$"#, options: .regularExpression) != nil,
            hostABI.range(of: #"^[A-Za-z0-9.-]{1,100}$"#, options: .regularExpression) != nil,
            hostExecutableSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        else { throw ProbeContractError.invalidFixtureField("metadata") }
        guard app == directory + "/Host.app", executable == app + "/Contents/MacOS/Edith",
            carrier == directory + "/support/Edith Tests/remote-" + suffix
                + "/Extensions/calendar/" + hostABI + "/arm64/" + version
                + "/calendar/ExtensionCarrier.app",
            worker == carrier + "/Contents/Extensions/ExtensionWorker.appex"
        else { throw ProbeContractError.invalidFixtureField("nestedRolePaths") }
        for path in [directory, app, executable, carrier, worker] {
            guard !path.utf8.contains(0), !path.contains("\n"), path.utf8.count <= 4096,
                URL(fileURLWithPath: path).standardizedFileURL.path == path
            else { throw ProbeContractError.invalidFixtureField("noncanonicalPath") }
        }
    }
}

public struct ProbeApprovalControl: Sendable {
    public let kind: String
    public let labels: [String]
    public let value: String?
    public let enabled: Bool
    public let hittable: Bool

    public init(kind: String, labels: [String], value: String?, enabled: Bool, hittable: Bool) {
        self.kind = kind
        self.labels = labels
        self.value = value
        self.enabled = enabled
        self.hittable = hittable
    }
}

public enum ProbeApproval {
    public static func select(_ controls: [ProbeApprovalControl], expectedLabel: String) throws
        -> Int
    {
        guard controls.count <= 128, !expectedLabel.isEmpty else {
            throw ProbeContractError.ambiguousControl
        }
        let matches = controls.indices.filter { controls[$0].labels.contains(expectedLabel) }
        guard matches.count == 1, let index = matches.first else {
            throw ProbeContractError.ambiguousControl
        }
        let control = controls[index]
        guard ["checkbox", "switch"].contains(control.kind), control.enabled, control.hittable,
            control.value == "0" || control.value == "1"
        else { throw ProbeContractError.unsupportedControl }
        return index
    }

    public static func validateManagedProof(_ data: Data, fixture: ProbeFixture) throws {
        guard data.count <= 16_384,
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["outcome"] as? String == "passed",
            value["extensionID"] as? String == fixture.extensionID,
            value["selectedVersion"] as? String == fixture.version,
            value["hostABI"] as? String == fixture.hostABI,
            value["nativeWindow"] as? Bool == false,
            value["disabledProcesses"] as? Int == 0
        else { throw ProbeContractError.incompleteProof }
        for key in [
            "managedNativeViewValidated", "originalDownloadedRole", "readonlyControlVerified",
            "publicCarrierCheckIn", "freshSceneGeneration", "lastCloseExited",
            "disableExitedBothRoles", "packageLeaseReleased", "noVisibleWindows",
        ] {
            guard value[key] as? Bool == true else { throw ProbeContractError.incompleteProof }
        }
    }
}

public enum ProbeLaunch {
    public enum Mode: Sendable { case approval, registration }
    public struct Request: Sendable {
        public let mode: Mode
        public let directory: URL
    }

    private static let modes = [
        "--extension-hosted-approval-probe", "--extension-hosted-register-probe",
    ]

    public static func diagnosticKinds(_ arguments: [String], directory: URL) -> [String] {
        Array(arguments.prefix(128)).map { value in
            switch value {
            case modes[0]: "approval-mode"
            case modes[1]: "registration-mode"
            case directory.path: "fixture-directory"
            case "-ApplePersistenceIgnoreState": "cocoa-persistence"
            case "-NSTreatUnknownArgumentsAsOpen": "cocoa-open"
            case "-NSDocumentRevisionsDebugMode": "cocoa-revisions"
            case "YES": "boolean-yes"
            case "NO": "boolean-no"
            default: value.hasPrefix("-psn_") ? "launch-serial" : "other"
            }
        }
    }

    public static func requested(_ arguments: [String]) -> Bool {
        arguments.contains { modes.contains($0) }
    }

    public static func candidateDirectory(_ arguments: [String]) throws -> URL {
        let indices = arguments.indices.filter { modes.contains(arguments[$0]) }
        guard arguments.count <= 128, indices.count == 1, let index = indices.first,
            arguments.indices.contains(index + 1)
        else { throw ProbeContractError.invalidFixtureField("launchArguments") }
        let path = arguments[index + 1]
        guard path.hasPrefix("/"), !path.utf8.contains(0), !path.contains("\n"),
            !path.contains("\r"), path.utf8.count <= 4096,
            URL(fileURLWithPath: path).standardizedFileURL.path == path
        else { throw ProbeContractError.invalidFixtureField("launchDirectory") }
        return URL(fileURLWithPath: path)
    }

    public static func parse(_ arguments: [String]) throws -> Request {
        let directory = try candidateDirectory(arguments)
        guard arguments.count == 2, modes.contains(arguments[0]) else {
            throw ProbeContractError.invalidFixtureField("launchArguments")
        }
        return Request(
            mode: arguments[0] == modes[0] ? .approval : .registration, directory: directory)
    }
}
