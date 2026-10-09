import Darwin
import Foundation
import Security

public enum CameraProviderProcessReader {
    public static func exited(identifier: String, team: String) throws -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count >= 0, count < 32768 else { throw CocoaError(.fileReadUnknown) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let received = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard received >= 0, received < pids.count else { throw CocoaError(.fileReadUnknown) }
        for pid in pids.prefix(Int(received)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let location = String(cString: path)
            guard location.contains("/" + identifier + ".systemextension/Contents/MacOS/") else {
                continue
            }
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
            let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
            if status != errSecSuccess {
                if kill(pid, 0) != 0, errno == ESRCH { continue }
                throw CocoaError(.fileReadNoPermission)
            }
            guard let code else { throw CocoaError(.fileReadNoPermission) }
            var requirement: SecRequirement?
            guard
                SecRequirementCreateWithString(
                    "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
                        as CFString, [], &requirement) == errSecSuccess,
                let requirement,
                SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                    == errSecSuccess
            else { throw CocoaError(.fileReadNoPermission) }
            return false
        }
        return true
    }
}
