import AppKit

@MainActor enum HostRestart {
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "edith-restart", String(getpid()), Bundle.main.bundleURL.path,
        ]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
