import Foundation

public struct WorkerFixturePresentationScope: Equatable, Sendable {
    public let location: String
    public let section: String

    public init(location: String, section: String) throws {
        guard ["main", "settings"].contains(location),
            WorkerFixtureUIContract.owners.contains(section)
                || (location == "settings"
                    && ["general", "appearance", "extensions", "extension"].contains(section))
        else { throw WorkerFixtureError.invalid }
        self.location = location; self.section = section
    }
}

public struct WorkerFixtureInputScope: Equatable, Sendable {
    public let name: String
    public let maximumBytes: Int

    public init(name: String, maximumBytes: Int) throws {
        guard WorkerFixtureRolePolicy.token(name), maximumBytes > 0, maximumBytes <= 268_435_456
        else { throw WorkerFixtureError.invalid }
        self.name = name; self.maximumBytes = maximumBytes
    }
}

public struct WorkerFixtureRolePolicy: Equatable, Sendable {
    public let owner: String
    public let primaryRole: WorkerFixtureRole
    public let operations: [String]
    public let presentations: [WorkerFixturePresentationScope]
    public let inputs: [WorkerFixtureInputScope]
    public let outputs: [String]
    public let manifestSHA256: String
    public let caseSHA256: String

    public init(
        owner: String, primaryRole: WorkerFixtureRole, operations: [String],
        presentations: [WorkerFixturePresentationScope], inputs: [WorkerFixtureInputScope],
        outputs: [String], manifestSHA256: String, caseSHA256: String
    ) throws {
        guard WorkerFixtureUIContract.owners.contains(owner),
            primaryRole == (WorkerFixtureUIContract.helperOwners.contains(owner) ? .helper : .app),
            !operations.isEmpty, operations.count <= 16,
            operations.allSatisfy(Self.token), Set(operations).count == operations.count,
            !presentations.isEmpty, presentations.count <= 8,
            presentations.allSatisfy({
                $0.section == owner
                    || ($0.location == "settings"
                        && ["general", "appearance", "extensions", "extension"].contains($0.section))
            }),
            Set(presentations.map { $0.location + "." + $0.section }).count == presentations.count,
            inputs.count <= 64, outputs.count <= 64, outputs.allSatisfy(Self.token),
            Set(inputs.map(\.name) + outputs).count == inputs.count + outputs.count,
            WorkerFixtureUIContract.hex(manifestSHA256, count: 64),
            WorkerFixtureUIContract.hex(caseSHA256, count: 64)
        else { throw WorkerFixtureError.invalid }
        self.owner = owner; self.primaryRole = primaryRole; self.operations = operations
        self.presentations = presentations; self.inputs = inputs; self.outputs = outputs
        self.manifestSHA256 = manifestSHA256; self.caseSHA256 = caseSHA256
    }

    public func validateEngine(_ value: WorkerFixtureEngineContract) throws {
        guard value.owner == owner, value.role == primaryRole.rawValue,
            value.operations == operations, value.inputs.count == inputs.count,
            zip(value.inputs, inputs).allSatisfy({
                $0.name == $1.name && $0.maximumBytes == $1.maximumBytes
            }),
            value.outputs.map(\.name) == outputs
        else { throw WorkerFixtureError.invalid }
    }

    public func validateUI(_ value: WorkerFixtureUIContract) throws {
        guard value.owner == owner,
            value.rolePath == value.workerPath + "/Contents/Resources/Payload/" + owner + "/"
                + primaryRole.rawValue + ".bundle",
            presentations.contains(where: {
                $0.location == value.location && $0.section == value.section
            })
        else { throw WorkerFixtureError.invalid }
    }

    static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            }
    }
}
