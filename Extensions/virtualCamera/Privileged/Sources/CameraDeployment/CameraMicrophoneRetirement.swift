import Foundation

public final class CameraMicrophoneRetirement {
    private var pendingBoot: String?
    private let boot: String
    private let installed: () throws -> Bool
    private let remove: () throws -> Void
    private let save: (String?) throws -> Void
    public init(
        boot: String, pendingBoot: String?, installed: @escaping () throws -> Bool,
        remove: @escaping () throws -> Void, save: @escaping (String?) throws -> Void
    ) {
        self.boot = boot; self.pendingBoot = pendingBoot; self.installed = installed;
        self.remove = remove; self.save = save
    }
    public func retire() throws -> Bool {
        if let pendingBoot {
            if pendingBoot == boot {
                if try installed() { try remove() }
                return true
            }
            try save(nil); self.pendingBoot = nil
        }
        guard try installed() else { return false }
        try save(boot); pendingBoot = boot
        try remove()
        return true
    }
}
