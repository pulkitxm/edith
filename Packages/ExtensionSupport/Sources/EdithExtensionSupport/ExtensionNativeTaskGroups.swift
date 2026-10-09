import Darwin
import Foundation

public final class ExtensionNativeTaskGroups: @unchecked Sendable {
    public static let registered = Notification.Name("edith.extension.nativeTaskChildRegistered")
    private let lock = NSLock()
    private var identities: [Int32: ExtensionProcessIdentity] = [:]
    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: Self.registered, object: nil, queue: nil
        ) { [weak self] notification in
            guard let pid = notification.userInfo?["pid"] as? Int32,
                getpgid(pid) == pid, ExtensionNativeTask.isDescendant(pid, of: getpid()),
                let identity = ExtensionProcessIdentity.read(pid)
            else { return }
            self?.lock.withLock { self?.identities[pid] = identity }
        }
    }

    public func terminate() {
        let children = lock.withLock { () -> [ExtensionProcessIdentity] in
            let result = Array(identities.values)
            identities = [:]
            return result
        }
        for child in children where child.isAlive && getpgid(child.pid) == child.pid {
            kill(-child.pid, SIGKILL)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        terminate()
    }
}
