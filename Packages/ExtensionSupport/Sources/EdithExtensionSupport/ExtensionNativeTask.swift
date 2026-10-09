import Darwin
import Foundation

public enum ExtensionNativeTask {
    public static func registerDescendant(_ pid: Int32) throws {
        guard pid > 1, pid != getpid(), getpgid(pid) == pid, isDescendant(pid, of: getpid()) else {
            throw ExtensionPeerError.invalidRequest
        }
        try ExtensionCommandOwnership.register(pid)
    }

    public static func registerChild(_ pid: Int32) throws {
        guard ExtensionCommandOwnership.isWorker else { return }
        guard let owner = ProcessInfo.processInfo.environment["EDITH_EXTENSION_ID"],
            let endpoint = ExtensionPeerEndpoint.current(owner: owner)
        else { throw ExtensionPeerError.unavailable }
        let result = NativeRegistration()
        let task = Task.detached {
            do {
                let payload = try JSONEncoder().encode(Registration(pid: pid))
                _ = try await endpoint.invoke(
                    "extension.process.register", payload: payload, timeout: 5)
                result.finish(.success(()))
            } catch { result.finish(.failure(error)) }
        }
        guard result.semaphore.wait(timeout: .now() + 6) == .success else {
            task.cancel()
            throw ExtensionPeerError.unavailable
        }
        try result.value().get()
    }

    public static func isDescendant(_ pid: Int32, of parent: Int32) -> Bool {
        guard pid > 1, parent > 1, pid != parent else { return false }
        var next = pid
        for _ in 0..<16 {
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            guard proc_pidinfo(next, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else {
                return false
            }
            next = Int32(info.pbi_ppid)
            if next == parent { return true }
            if next <= 1 { return false }
        }
        return false
    }

    private struct Registration: Encodable { let pid: Int32 }
}

private final class NativeRegistration: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, any Error> = .failure(ExtensionPeerError.unavailable)
    func finish(_ value: Result<Void, any Error>) {
        lock.withLock { result = value }
        semaphore.signal()
    }
    func value() -> Result<Void, any Error> { lock.withLock { result } }
}
