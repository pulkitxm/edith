import Foundation

protocol WorkerFixtureTrustBounds {
    var sourceCommit: String { get }
    var session: String { get }
    var root: String { get }
    var hostIdentifier: String { get }
    var producerExecutable: String { get }
    var producerExecutableSHA256: String { get }
    func validate() throws
}

extension WorkerFixtureUITrust: WorkerFixtureTrustBounds {}

public struct WorkerFixtureBootstrapTrust: Sendable, WorkerFixtureTrustBounds {
    public let sourceCommit: String
    public let session: String
    public let root: String
    public let hostIdentifier: String
    public let issuerKey: Data
    public let hostRequirement: String
    public let hostCertificateSHA256: Data
    public let workerCertificateSHA256: Data
    public let roleCertificateSHA256: Data
    public let producerExecutable: String
    public let producerExecutableSHA256: String
    public let rolePolicies: [WorkerFixtureRolePolicy]

    public init(
        sourceCommit: String, session: String, root: String, issuerKey: Data,
        hostRequirement: String, hostCertificateSHA256: Data,
        workerCertificateSHA256: Data, roleCertificateSHA256: Data,
        producerExecutable: String, producerExecutableSHA256: String,
        rolePolicies: [WorkerFixtureRolePolicy] = []
    ) throws {
        self.sourceCommit = sourceCommit; self.session = session; self.root = root
        hostIdentifier = "com.pulkit.edith.tests.worker-" + session
        self.issuerKey = issuerKey; self.hostRequirement = hostRequirement
        self.hostCertificateSHA256 = hostCertificateSHA256
        self.workerCertificateSHA256 = workerCertificateSHA256
        self.roleCertificateSHA256 = roleCertificateSHA256
        self.producerExecutable = producerExecutable
        self.producerExecutableSHA256 = producerExecutableSHA256
        self.rolePolicies = rolePolicies
        try validate()
    }

    public func rolePolicy(owner: String) throws -> WorkerFixtureRolePolicy {
        guard let value = rolePolicies.first(where: { $0.owner == owner }) else {
            throw WorkerFixtureError.invalid
        }
        return value
    }

    func validate() throws {
        guard WorkerFixtureUIContract.hex(sourceCommit, count: 40),
            WorkerFixtureUIContract.uuid(session), WorkerFixtureUIContract.canonical(root),
            root.hasSuffix("/functional-fixture-" + session), issuerKey.count == 32,
            !hostRequirement.isEmpty, hostRequirement.utf8.count <= 1024,
            hostRequirement.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
            hostCertificateSHA256.count == 32, workerCertificateSHA256.count == 32,
            roleCertificateSHA256.count == 32,
            producerExecutable == root + "/Producer/functional-producer",
            WorkerFixtureUIContract.hex(producerExecutableSHA256, count: 64),
            rolePolicies.count <= 40, Set(rolePolicies.map(\.owner)).count == rolePolicies.count
        else { throw WorkerFixtureError.invalid }
    }
}
