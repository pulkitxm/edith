import Darwin
import Foundation

public struct ExtensionProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let generation: String

    public static var current: Self? { read(getpid()) }
    public var isAlive: Bool { self == Self.read(pid) }

    public static func read(_ pid: Int32) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return Self(pid: pid, generation: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)")
    }
}
