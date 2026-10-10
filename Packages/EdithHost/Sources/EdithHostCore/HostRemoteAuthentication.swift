import Darwin
import Foundation
import Security

public struct HostRemoteProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let generation: String
    public let executable: URL
    public let codeHash: Data

    public static func read(_ pid: Int32) throws -> Self {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        var path = [CChar](repeating: 0, count: 4096)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_uid == getuid(), info.pbi_ruid == getuid(),
            proc_pidpath(pid, &path, UInt32(path.count)) > 0
        else { throw HostWorkerError.rejected }
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(
                nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code)
                == errSecSuccess, let code,
            SecCodeCheckValidity(code, [], nil) == errSecSuccess
        else { throw HostWorkerError.rejected }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw HostWorkerError.rejected
        }
        return Self(
            pid: pid, generation: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)",
            executable: URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath(),
            codeHash: try hash(staticCode))
    }

    public static func verify(_ connection: NSXPCConnection, executable: URL) throws -> Self {
        guard connection.effectiveUserIdentifier == getuid() else {
            throw HostWorkerError.rejected
        }
        let peer = try read(connection.processIdentifier)
        let expected = executable.resolvingSymlinksInPath()
        var code: SecStaticCode?
        guard peer.executable == expected,
            SecStaticCodeCreateWithPath(expected as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
                == errSecSuccess,
            peer.codeHash == (try hash(code)), try read(peer.pid) == peer
        else { throw HostWorkerError.rejected }
        return peer
    }

    public var isRunning: Bool { (try? Self.read(pid)) == self }

    private static func hash(_ code: SecStaticCode) throws -> Data {
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let information = information as? [String: Any],
            let hash = information[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty
        else { throw HostWorkerError.rejected }
        return hash
    }
}
