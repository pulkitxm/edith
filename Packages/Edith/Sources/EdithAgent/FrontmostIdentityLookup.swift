import Darwin
import Foundation

struct FrontmostIdentity: Equatable, Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String?
}

struct FrontmostIdentityCache: Sendable {
    private var pid: pid_t = -1
    private var identity = FrontmostIdentity(pid: -1, name: "", bundleID: nil)
    private(set) var lookups = 0

    mutating func update(
        pid: pid_t, resolve: () -> (name: String, bundleID: String?)
    ) -> FrontmostIdentity {
        if pid == self.pid, pid > 0 { return identity }
        let resolved = resolve()
        lookups += 1
        identity = FrontmostIdentity(pid: pid, name: resolved.name, bundleID: resolved.bundleID)
        self.pid = pid
        return identity
    }
}

enum FrontmostIdentityLookup {
    private static let lock = NSLock()
    private static var cache = FrontmostIdentityCache()

    static func identity(
        pid: pid_t, resolve: () -> (name: String, bundleID: String?)
    ) -> FrontmostIdentity {
        lock.lock()
        defer { lock.unlock() }
        return cache.update(pid: pid, resolve: resolve)
    }

    static var lookups: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.lookups
    }

    static func reset() {
        lock.lock()
        cache = FrontmostIdentityCache()
        lock.unlock()
    }
}
