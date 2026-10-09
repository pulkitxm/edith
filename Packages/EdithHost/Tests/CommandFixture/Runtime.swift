import Darwin
import EdithExtensionSupport
import Foundation

@MainActor
@objc(EdithCommandFixtureRuntime)
final class CommandFixtureRuntime: NSObject {
    private var task: Task<Void, Never>?
    private var mode = ""

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            return [
                "id": "keepAwake", "version": "1.0.0", "hostABI": "edith-host-1", "role": "helper",
            ] as NSDictionary
        case "start":
            guard let path = input["dataDirectory"] as? String,
                let suite = input["defaultsSuite"] as? String,
                let defaults = UserDefaults(suiteName: suite),
                let mode = defaults.string(forKey: "commandFixtureMode")
            else { return ["ok": false] as NSDictionary }
            self.mode = mode
            let directory = URL(fileURLWithPath: path)
            task = Task {
                do {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    let binary = Data([0, 1, 127, 128, 255, 10])
                    let probe = try await CLICommandRunner.runLocalSeparated(
                        CLICommandRequest(
                            executableURL: URL(fileURLWithPath: "/bin/sh"),
                            arguments: [
                                "-c",
                                "printf '%s|%s|%s|%s' \"$PPID\" \"$TEST_VALUE\" \"$PWD\" \"$1\" >&2; exec /bin/cat",
                                "fixture", "literal \"quoted\" value",
                            ],
                            environment: ["PATH": "/usr/bin:/bin", "TEST_VALUE": "fixture value"],
                            currentDirectoryURL: directory, timeout: 3,
                            standardInputData: binary),
                        onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
                    try JSONEncoder().encode(probe).write(
                        to: directory.appendingPathComponent("probe.json"), options: .atomic)
                    let script = """
                        printf '%s\n' "$$" > "$1/parent.pid"
                        trap '' TERM
                        /bin/sleep 30 &
                        printf '%s\n' "$!" > "$1/child.pid"
                        if [ "$2" = completed ]; then exit 0; fi
                        wait
                        """
                    let result = try await CLICommandRunner.runLocal(
                        CLICommandRequest(
                            executableURL: URL(fileURLWithPath: "/bin/sh"),
                            arguments: ["-c", script, "fixture", directory.path, mode],
                            environment: ["PATH": "/usr/bin:/bin"], timeout: 20)
                    ) { _ in }
                    try JSONEncoder().encode(result).write(
                        to: directory.appendingPathComponent("result.json"), options: .atomic)
                } catch {
                    try? Data("failed".utf8).write(
                        to: directory.appendingPathComponent("failed"), options: .atomic)
                }
            }
            return ["ok": true] as NSDictionary
        case "stop":
            if mode == "hang" { Thread.sleep(forTimeInterval: 30) }
            task?.cancel()
            return ["ok": true] as NSDictionary
        case "status": return ["ok": true, "running": task != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
    }
}

@_cdecl("edith_extension_create")
public func createCommandFixture() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(CommandFixtureRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
