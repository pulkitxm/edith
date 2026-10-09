import Darwin
import Foundation

@MainActor public final class ExtensionNativeTaskAdmission {
    public let token = UUID().uuidString + UUID().uuidString
    private struct Identity: Equatable {
        let seconds: UInt64
        let microseconds: UInt64
    }
    private var processes: [Int32: Identity] = [:]
    public init() {}
    public func authorize(_ pid: Int32, token: String) throws {
        processes = processes.filter { identity($0.key) == $0.value }
        guard token == self.token, pid > 1, pid != getpid(), getpgid(pid) == pid,
            processes.count < 128 || processes[pid] != nil,
            let identity = identity(pid), let current = executable(getpid()),
            executable(pid) == current
        else { throw ExtensionPeerError.invalidRequest }
        try ExtensionCommandOwnership.register(pid)
        processes[pid] = identity
    }
    public func registerDescendant(_ pid: Int32) throws {
        guard pid > 1, pid != getpid(), getpgid(pid) == pid,
            ExtensionNativeTask.isDescendant(pid, of: getpid())
                || processes.contains(where: {
                    identity($0.key) == $0.value
                        && ExtensionNativeTask.isDescendant(pid, of: $0.key)
                })
        else { throw ExtensionPeerError.invalidRequest }
        try ExtensionCommandOwnership.register(pid)
    }
    private func identity(_ pid: Int32) -> Identity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_uid == getuid()
        else { return nil }
        return Identity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    private func executable(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }
}
