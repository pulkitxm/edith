import AppKit

@MainActor enum HostApplicationRelaunch {
    static let waitTenths = 600

    static func arguments(pid: Int32, bundlePath: String) -> [String] {
        [
            "-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt \(waitTenths) ]; "
                + "do sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$2\"",
            "edith-relaunch", String(pid), bundlePath,
        ]
    }

    static func perform(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        bundleURL: URL = Bundle.main.bundleURL,
        spawn: (String, [String]) -> Bool = HostApplicationRelaunch.spawnDetached,
        terminate: @MainActor () -> Void = { HostQuit.terminate() }
    ) {
        guard bundleURL.pathExtension == "app",
            spawn("/bin/sh", arguments(pid: pid, bundlePath: bundleURL.path))
        else { return }
        terminate()
    }

    nonisolated static func spawnDetached(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
