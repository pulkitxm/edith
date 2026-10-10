import Darwin
import Foundation

public final class ExtensionNativeTaskGroups: @unchecked Sendable {
    public static let registered = Notification.Name("edith.extension.nativeTaskChildRegistered")
    private let lock = NSLock()
    private var identities: [Int32: ExtensionProcessIdentity] = [:]
    private var observer: NSObjectProtocol?
    private var terminating = false
    private let maximumTrackedGroups: Int

    public convenience init() { self.init(maximumTrackedGroups: 128) }

    init(maximumTrackedGroups: Int) {
        self.maximumTrackedGroups = min(128, max(1, maximumTrackedGroups))
        observer = NotificationCenter.default.addObserver(
            forName: Self.registered, object: nil, queue: nil
        ) { [weak self] notification in
            guard let pid = notification.userInfo?["pid"] as? Int32,
                getpgid(pid) == pid, ExtensionNativeTask.isDescendant(pid, of: getpid()),
                let identity = ExtensionProcessIdentity.read(pid)
            else { return }
            guard let self else { return }
            let rejected = self.lock.withLock {
                if self.terminating { return true }
                if self.identities.count >= self.maximumTrackedGroups {
                    self.identities = self.identities.filter { $0.value.isAlive }
                }
                guard
                    self.identities[pid] != nil || self.identities.count < self.maximumTrackedGroups
                else {
                    return true
                }
                self.identities[pid] = identity
                return false
            }
            if rejected && identity.isAlive && getpgid(pid) == pid { kill(-pid, SIGKILL) }
        }
    }

    public func terminate() {
        let children = lock.withLock { () -> [ExtensionProcessIdentity] in
            terminating = true
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
