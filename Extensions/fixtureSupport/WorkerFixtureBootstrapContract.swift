import Foundation

public enum WorkerFixtureBootstrapPurpose: Sendable { case engine, ui }

public enum WorkerFixtureBootstrapContract: Sendable {
    case engine(WorkerFixtureEngineContract)
    case ui(WorkerFixtureUIContract)

    public static func verify(
        _ data: Data, purpose: WorkerFixtureBootstrapPurpose, trust: WorkerFixtureBootstrapTrust,
        owner: String, expectedRole: WorkerFixtureRole, uid: UInt32,
        engineDescriptorData: Data? = nil
    ) throws -> Self {
        try trust.validate()
        switch purpose {
        case .engine:
            guard engineDescriptorData == nil else { throw WorkerFixtureError.invalid }
            let value = try WorkerFixtureEngineContract.verify(data, issuerKey: trust.issuerKey)
            try value.validate(trust: trust, owner: owner, uid: uid, expectedRole: expectedRole)
            return .engine(value)
        case .ui:
            guard owner != "notchShelf" || expectedRole != .helper || engineDescriptorData != nil
            else { throw WorkerFixtureError.invalid }
            let value = try WorkerFixtureUIContract.verify(data, issuerKey: trust.issuerKey)
            guard value.producer.executable == trust.producerExecutable,
                value.producer.executableSHA256 == trust.producerExecutableSHA256
            else { throw WorkerFixtureError.invalid }
            try value.validate(
                sourceCommit: trust.sourceCommit, session: trust.session, owner: owner,
                presentationID: value.presentationID, phase: value.phase,
                location: value.location, section: value.section,
                capabilitySHA256: value.capabilitySHA256, root: trust.root,
                dataDirectory: trust.root + "/data/" + owner, workerPath: value.workerPath,
                rolePath: value.workerPath + "/Contents/Resources/Payload/" + owner + "/"
                    + expectedRole.rawValue + ".bundle", version: value.version, uid: uid,
                producer: value.producer, engine: value.engine, ui: value.ui)
            if let engineDescriptorData {
                guard owner == "notchShelf", expectedRole == .helper else {
                    throw WorkerFixtureError.invalid
                }
                let service = try WorkerFixtureEngineContract.verify(
                    engineDescriptorData, issuerKey: trust.issuerKey)
                try service.validate(trust: trust, owner: owner, uid: uid, expectedRole: .helper)
                try value.validateSettingsService(service)
            }
            return .ui(value)
        }
    }

    public static func validateContext(
        _ context: NSDictionary, environment: [String: String],
        purpose: WorkerFixtureBootstrapPurpose,
        trust: WorkerFixtureBootstrapTrust, owner: String, expectedRole: WorkerFixtureRole,
        workerIdentifier: String, settingsService: WorkerFixtureEngineContract? = nil
    ) throws {
        try validateIsolationContext(
            context, environment: environment, trust: trust, owner: owner,
            workerIdentifier: workerIdentifier)
        switch purpose {
        case .engine:
            guard settingsService == nil else { throw WorkerFixtureError.invalid }
            try WorkerFixtureEngineContract.validateContext(
                context, environment: environment, owner: owner, workerIdentifier: workerIdentifier)
        case .ui:
            guard context["operation"] as? String == "configureUI" else {
                throw WorkerFixtureError.invalid
            }
            try WorkerFixtureUIContract.validateUIContext(
                context, environment: environment, owner: owner, workerIdentifier: workerIdentifier,
                role: expectedRole, settingsService: settingsService)
        }
    }

    public static func validateIsolationContext(
        _ context: NSDictionary, environment: [String: String], trust: WorkerFixtureBootstrapTrust,
        owner: String, workerIdentifier: String
    ) throws {
        try trust.validate()
        guard WorkerFixtureUIContract.owners.contains(owner),
            context["hostIdentifier"] as? String == trust.hostIdentifier,
            context["dataDirectory"] as? String == trust.root + "/data/" + owner,
            environment["HOME"] == trust.root + "/" + owner + "-home",
            environment["CFFIXED_USER_HOME"] == environment["HOME"],
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == environment["HOME"],
            environment["EDITH_EXTENSION_DATA_ROOT"] == context["dataDirectory"] as? String,
            workerIdentifier == trust.hostIdentifier + ".extension." + owner + ".worker"
        else { throw WorkerFixtureError.invalid }
    }

    public func validateMarker(_ marker: NSDictionary) throws {
        guard let marker = marker as? [String: String], marker == contextMarker
        else { throw WorkerFixtureError.invalid }
    }

    public var contextMarker: [String: String] {
        switch self {
        case .engine(let value):
            return [
                "sourceCommit": value.sourceCommit, "session": value.session, "phase": value.phase,
                "descriptorPath": value.root + "/functional-engine-" + value.owner + ".json",
                "capabilitySHA256": value.capabilitySHA256,
                "requestGeneration": value.requestGeneration,
            ]
        case .ui(let value):
            return [
                "sourceCommit": value.sourceCommit, "session": value.session, "phase": value.phase,
                "descriptorPath": value.root + "/functional-ui-" + value.owner + ".json",
                "capabilitySHA256": value.capabilitySHA256,
            ]
        }
    }

    var workerPath: String {
        switch self {
        case .engine(let value): return value.workerPath
        case .ui(let value): return value.workerPath
        }
    }
    var rolePath: String {
        switch self {
        case .engine(let value): return value.rolePath
        case .ui(let value): return value.rolePath
        }
    }
    var version: String {
        switch self {
        case .engine(let value): return value.version
        case .ui(let value): return value.version
        }
    }
    var producer: WorkerFixtureUIProcess {
        switch self {
        case .engine(let value): return value.producer
        case .ui(let value): return value.producer
        }
    }
    var engine: WorkerFixtureUIProcess {
        switch self {
        case .engine(let value): return value.engine
        case .ui(let value): return value.engine
        }
    }
    var currentProcess: WorkerFixtureUIProcess {
        switch self {
        case .engine(let value): return value.engine
        case .ui(let value): return value.ui
        }
    }
}
