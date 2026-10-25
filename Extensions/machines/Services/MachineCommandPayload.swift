import CoreFoundation
import EdithExtensionSupport
import Foundation

public enum MachineCommandPayload {
    public static func decode<T: Decodable>(
        _ type: T.Type, data: Data, required: Set<String>, optional: Set<String> = []
    ) throws -> T {
        guard data.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            required.isSubset(of: Set(object.keys)),
            Set(object.keys).isSubset(of: required.union(optional))
        else { throw ExtensionPeerError.invalidRequest }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func empty(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object.isEmpty
        else { throw ExtensionPeerError.invalidRequest }
    }

    public static func valid(_ machine: Machine) -> Bool {
        let target: String
        switch machine.source {
        case .manual: target = machine.host
        case .sshConfigAlias(let alias): target = alias
        }
        return machine.id != Machine.localID && !machine.isMissing && !machine.name.isEmpty
            && machine.name.utf8.count <= 512 && !target.isEmpty
            && target.utf8.count <= 1_024 && !target.hasPrefix("-")
            && !target.contains(where: { $0.isWhitespace || $0.isNewline })
            && !target.utf8.contains(0) && (1...65_535).contains(machine.port)
            && machine.username.utf8.count <= 512 && !machine.username.utf8.contains(0)
    }
}
