import Darwin
import EdithExtensionSupport
import Foundation
import Security

public enum HostCoreAdmission {
    public static func admitParent() throws -> ExtensionProcessIdentity {
        let pid = getppid()
        var metadata = stat()
        var information = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard pid > 1, fstat(STDIN_FILENO, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFIFO,
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, Int32(size)) == size,
            information.pbi_uid == getuid(),
            path(pid) == path(getpid()), path(pid) != nil,
            let identity = ExtensionProcessIdentity.read(pid),
            try signature(pid) == signature(getpid()), identity.isAlive
        else { throw HostWorkerError.rejected }
        return identity
    }

    private static func path(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

    private static func signature(_ pid: Int32) throws -> Data {
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(
                nil,
                [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code)
                == errSecSuccess,
            let code,
            SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
                == errSecSuccess
        else { throw HostWorkerError.rejected }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw HostWorkerError.rejected
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let values = information as? [String: Any],
            let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty
        else { throw HostWorkerError.rejected }
        return hash
    }
}
