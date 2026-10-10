import Darwin
import Foundation

public struct ExtensionSharedState: Sendable {
    private struct Snapshot: Codable {
        let pid: Int32
        let generation: String
        let values: [String: String]
    }

    public let root: URL
    public let namespace: String
    public let owner: String?
    public var notificationName: Notification.Name {
        Notification.Name(namespace + ".extensionSharedStateChanged")
    }

    public static var current: Self? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EDITH_EXTENSION_STATE_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0), let namespace = environment["EDITH_APPLICATION_IDENTIFIER"],
            let owner = environment["EDITH_EXTENSION_ID"], validOwner(owner)
        else { return nil }
        return Self(root: URL(fileURLWithPath: path), namespace: namespace, owner: owner)
    }

    public init(root: URL, namespace: String, owner: String? = nil) {
        self.root = root
        self.namespace = namespace
        self.owner = owner
    }

    public func publish(_ values: [String: String]) throws {
        guard let owner, Self.validOwner(owner), values.count <= 128,
            values.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 }),
            let generation = Self.generation(getpid())
        else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try JSONEncoder().encode(
            Snapshot(pid: getpid(), generation: generation, values: values))
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = file(owner)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        notify(owner)
    }

    public func values(for owner: String) -> [String: String] {
        guard Self.validOwner(owner),
            let handle = try? FileHandle(forReadingFrom: file(owner))
        else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
            snapshot.pid > 1, Self.generation(snapshot.pid) == snapshot.generation
        else { return [:] }
        return snapshot.values
    }

    public func clear(_ owner: String) throws {
        guard Self.validOwner(owner) else { throw CocoaError(.fileWriteInvalidFileName) }
        let file = file(owner)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        notify(owner)
    }

    public func observe(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { notification in
            guard let owner = notification.userInfo?["owner"] as? String, Self.validOwner(owner)
            else { return }
            handler(owner)
        }
    }

    public func stopObserving(_ token: NSObjectProtocol?) {
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
    }

    private func notify(_ owner: String) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: nil, userInfo: ["owner": owner], deliverImmediately: true)
    }

    private func file(_ owner: String) -> URL { root.appendingPathComponent(owner + ".json") }

    private static func validOwner(_ owner: String) -> Bool {
        !owner.isEmpty && owner.count <= 96 && owner != "." && owner != ".."
            && !owner.hasPrefix(".")
            && owner.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            }
    }

    private static func generation(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }
}
