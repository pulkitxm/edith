import Darwin
import Dispatch
import Foundation

@main enum FunctionalProcessProbe {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data("process probe rejected\n".utf8))
            _exit(1)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "--require-absent" {
            try observeAbsent(arguments)
            return
        }
        guard arguments.count == 8,
            let deadline = Int(arguments[7]), (1000...10_000).contains(deadline),
            String(deadline) == arguments[7],
            let pid = Int32(arguments[1]), pid > 1, String(pid) == arguments[1],
            validText(arguments[2], maximum: 4096), arguments[2].hasPrefix("/"),
            FunctionalBytes.hex(arguments[3], length: 64),
            validText(arguments[4], maximum: 256),
            let certificate = Data(base64Encoded: arguments[5]), certificate.count == 32,
            certificate.base64EncodedString() == arguments[5],
            validText(arguments[6], maximum: 1024)
        else { throw FunctionalFailure.invalid("process probe arguments") }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(deadline)
        ) {
            _exit(124)
        }
        let url = URL(fileURLWithPath: arguments[2])
        let pinned = try FunctionalPinnedPath(url, directory: false)
        guard FunctionalBytes.digest(try pinned.read()) == arguments[3]
        else { throw FunctionalFailure.invalid("process probe executable pin") }
        let birth = try FunctionalBirth.observe(pid)
        guard birth.executable == arguments[2], birth.executableSHA256 == arguments[3]
        else { throw FunctionalFailure.invalid("process probe identity") }
        try FunctionalSigner(
            identifier: arguments[4], certificateSHA256: certificate,
            requirement: arguments[6]
        ).verify(url, birth: birth)
        try pinned.requireCurrent()
        try birth.requireCurrent()
        let output = try FunctionalBytes.canonical(["schema": 1, "birth": birth.object])
        guard output.count <= 16_384 else {
            throw FunctionalFailure.invalid("process probe output")
        }
        FileHandle.standardOutput.write(output)
    }

    private static func observeAbsent(_ arguments: [String]) throws {
        guard arguments.count == 7,
            let pid = Int32(arguments[2]), pid > 1, String(pid) == arguments[2],
            let seconds = UInt64(arguments[3]), seconds > 0, String(seconds) == arguments[3],
            let microseconds = UInt64(arguments[4]), microseconds < 1_000_000,
            String(microseconds) == arguments[4],
            let uid = UInt32(arguments[5]), String(uid) == arguments[5],
            let deadline = Int(arguments[6]), (1000...10_000).contains(deadline),
            String(deadline) == arguments[6]
        else { throw FunctionalFailure.invalid("recorded process absence arguments") }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(deadline)
        ) { _exit(124) }
        var state = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &state, size)
        let basis: String
        let current: Any
        if result == 0, errno == ESRCH {
            basis = "pid-missing"
            current = NSNull()
        } else if result == size,
            state.pbi_start_tvsec != seconds || state.pbi_start_tvusec != microseconds
        {
            basis = "pid-reused"
            current = [
                "birthSeconds": state.pbi_start_tvsec, "birthMicroseconds": state.pbi_start_tvusec,
                "uid": state.pbi_uid,
            ]
        } else {
            throw FunctionalFailure.invalid("recorded birth remains present or unverifiable")
        }
        let output = try FunctionalBytes.canonical([
            "schema": 1,
            "recordedBirth": [
                "pid": pid,
                "birthSeconds": seconds, "birthMicroseconds": microseconds, "uid": uid,
            ], "basis": basis, "currentBirth": current,
        ])
        guard output.count <= 16_384 else {
            throw FunctionalFailure.invalid("recorded absence output")
        }
        FileHandle.standardOutput.write(output)
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.utf8.allSatisfy { (32...126).contains($0) }
    }
}
