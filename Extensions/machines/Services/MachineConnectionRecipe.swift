import EdithExtensionSupport
import Foundation

public struct MachineConnectionRecipe: Codable, Equatable, Sendable {
    public let machineID: UUID
    public let name: String
    public let sshTarget: String
    public let sshArguments: [String]
    public let controlPath: String
    public let platform: RemoteMachinePlatform

    public static let masterOnlyOptions = [
        "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false",
    ]

    public init(
        machine: Machine, sshArguments: [String], controlPath: String,
        platform: RemoteMachinePlatform
    ) throws {
        guard Self.valid(machine), controlPath.hasPrefix("/"),
            Self.text(controlPath, maximum: 4_096),
            Array(sshArguments.prefix(Self.masterOnlyOptions.count)) == Self.masterOnlyOptions,
            sshArguments.count <= 128, sshArguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
            sshArguments.allSatisfy({ Self.text($0, maximum: 4_096) }),
            sshArguments.filter({ $0 == "-S" }).count == 1,
            let socket = sshArguments.firstIndex(of: "-S"), socket + 1 < sshArguments.count,
            sshArguments[socket + 1] == controlPath, sshArguments.last == machine.sshTarget
        else {
            throw ExtensionPeerError.invalidRequest
        }
        machineID = machine.id; name = machine.name; sshTarget = machine.sshTarget
        self.sshArguments = sshArguments; self.controlPath = controlPath; self.platform = platform
    }

    static func valid(_ machine: Machine) -> Bool {
        MachineCommandPayload.valid(machine) && Self.text(machine.name, maximum: 512)
            && !machine.sshTarget.hasPrefix("-")
            && Self.text(machine.sshTarget, maximum: 1_536)
            && !machine.sshTarget.contains(where: { $0.isWhitespace })
    }

    private static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
