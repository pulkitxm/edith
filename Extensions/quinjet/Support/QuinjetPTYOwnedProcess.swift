import Darwin
import Foundation

public enum QuinjetPTYOwnedProcess {
    public static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        for value in [SIGTERM, SIGKILL] {
            if getpgid(pid) == pid { kill(-pid, value) }
            kill(pid, value)
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if !process.isRunning { break }
        }
        process.waitUntilExit()
    }
}
