import Darwin
import Foundation

enum ExtensionPrivilegedCarrierProcess {
    static func predatesHost(
        executable: URL? = Bundle.main.executableURL, user: uid_t = 0, parent: pid_t = 1
    ) -> Bool {
        guard let executable, let installed = changeTime(of: executable) else { return false }
        return startTimes(named: executable.lastPathComponent, user: user, parent: parent)
            .contains { $0 < installed }
    }

    static func changeTime(of url: URL) -> Double? {
        var metadata = stat()
        guard stat(url.path, &metadata) == 0 else { return nil }
        return Double(metadata.st_ctimespec.tv_sec) + Double(metadata.st_ctimespec.tv_nsec) / 1e9
    }

    static func startTimes(named name: String, user: uid_t, parent: pid_t) -> [Double] {
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: user)]
        var size = 0
        guard sysctl(&request, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&request, 4, &processes, &size, nil, 0) == 0 else { return [] }
        let command = String(decoding: name.utf8.prefix(Int(MAXCOMLEN)), as: UTF8.self)
        return processes.prefix(size / stride).compactMap { process in
            guard process.kp_eproc.e_ppid == parent, commandName(of: process) == command else {
                return nil
            }
            let started = process.kp_proc.p_un.__p_starttime
            return Double(started.tv_sec) + Double(started.tv_usec) / 1e6
        }
    }

    private static func commandName(of process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
