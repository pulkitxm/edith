import Foundation
import Security

public enum MachineSecretKind: String, Sendable {
    case password
    case passphrase
    case sudoPassword
}

public enum MachineSecrets {
    public static let service = "com.pulkit.edith.machines"

    public static func account(machineID: UUID, kind: MachineSecretKind) -> String {
        "\(machineID.uuidString).\(kind.rawValue)"
    }

    public static func set(_ secret: String, machineID: UUID, kind: MachineSecretKind) {
        let name = account(machineID: machineID, kind: kind)
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Edith Machines"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func get(machineID: UUID, kind: MachineSecretKind) -> String? {
        get(account: account(machineID: machineID, kind: kind))
    }

    public static func get(account name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(machineID: UUID, kind: MachineSecretKind) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(machineID: machineID, kind: kind),
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func deleteAll(machineID: UUID) {
        delete(machineID: machineID, kind: .password)
        delete(machineID: machineID, kind: .passphrase)
        delete(machineID: machineID, kind: .sudoPassword)
    }
}

public enum SudoPassword {
    public static let hint =
        "store this account's sudo password with `ed machines edit <machine> "
        + "--sudo-password-stdin`, or give it passwordless sudo for systemctl"

    public static let refusedHint =
        "the stored sudo password was refused; replace it with `ed machines edit <machine> "
        + "--sudo-password-stdin`"

    public static func hint(forRefusal detail: String) -> String? {
        if PowerOutcome.sudoPasswordRefused(detail) { return refusedHint }
        return PowerOutcome.needsPrivilege(detail) ? hint : nil
    }

    public static func stored(machineID: UUID) -> String? {
        guard let secret = MachineSecrets.get(machineID: machineID, kind: .sudoPassword),
            !secret.isEmpty
        else { return nil }
        return secret
    }

    public static func isStored(machineID: UUID) -> Bool {
        stored(machineID: machineID) != nil
    }

    public static func stdin(machineID: UUID) -> Data? {
        guard let secret = stored(machineID: machineID) else { return nil }
        return Data((secret + "\n").utf8)
    }
}
