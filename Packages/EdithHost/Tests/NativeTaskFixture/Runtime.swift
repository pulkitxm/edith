import Darwin
import EdithExtensionSupport
import Foundation

@MainActor @objc(EdithNativeTaskFixtureRuntime)
final class NativeTaskFixtureRuntime: NSObject {
    private let commands = ExtensionCommandRegistry()
    private var task: Task<Void, Never>?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [self] command, payload in
            switch command {
            case "native.echo":
                let result = try await run(Data([1]), input: Data([0, 1, 127, 128, 255, 10]))
                return try JSONSerialization.data(withJSONObject: [
                    "status": result.terminationStatus,
                    "output": result.standardOutputData.base64EncodedString(),
                    "error": result.standardErrorData.base64EncodedString(),
                ])
            case "native.returnWithChild":
                let result = try await run(Data([3]), input: Data())
                return try JSONSerialization.data(withJSONObject: [
                    "status": result.terminationStatus
                ])
            case "native.launch":
                task = Task { _ = try? await run(Data([2]), input: Data()) }
                return Data("{}".utf8)
            case "native.cancel":
                task?.cancel()
                await task?.value
                task = nil
                return Data("{}".utf8)
            case "native.contextMismatch":
                var environment = ProcessInfo.processInfo.environment
                environment["EDITH_EXTENSION_NATIVE_CONTEXT"] = Data("{}".utf8)
                    .base64EncodedString()
                let result = try await run(Data([1]), input: Data(), environment: environment)
                return try JSONSerialization.data(withJSONObject: [
                    "status": result.terminationStatus
                ])
            case "native.oversize":
                let process = Process()
                process.executableURL = Bundle.main.executableURL
                process.arguments = [
                    "--extension-native-task",
                    Data(repeating: 1, count: 65_537).base64EncodedString(),
                ]
                process.environment = ProcessInfo.processInfo.environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                return try JSONSerialization.data(withJSONObject: [
                    "status": process.terminationStatus
                ])
            case "native.malformed":
                let result = try await run(Data(), input: Data())
                return try JSONSerialization.data(withJSONObject: [
                    "status": result.terminationStatus
                ])
            default: throw ExtensionPeerError.invalidRequest
            }
        }
    }

    private func run(
        _ payload: Data, input: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> CLICommandResult {
        try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: Bundle.main.executableURL!,
                arguments: ["--extension-native-task", payload.base64EncodedString()],
                environment: environment, timeout: 30, standardInputData: input),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
    }

    @objc(prepareToStopWithCompletion:) func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        task?.cancel()
        Task {
            await task?.value; completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        if input["operation"] as? String == "describe" {
            return [
                "id": "keepAwake", "version": "1.0.0", "hostABI": "edith-host-1", "role": "app",
            ] as NSDictionary
        }
        if input["operation"] as? String == "stop" { task?.cancel() }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createNativeTaskFixture() -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated { Unmanaged.passRetained(NativeTaskFixtureRuntime()).toOpaque() }
}

@_cdecl("edith_extension_native_task")
public func executeNativeTaskFixture(_ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    guard let bytes, count > 0 else { return 1 }
    let root = ExtensionData.root
    try? Data(String(getpid()).utf8).write(to: root.appendingPathComponent("native.pid"))
    if bytes[0] == 1 {
        FileHandle.standardOutput.write(FileHandle.standardInput.readDataToEndOfFile())
        return 7
    }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return 1 }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
    else { return 1 }
    let strings = ["/bin/sleep", "60"].map { $0.withCString { strdup($0) } }
    defer { strings.forEach { free($0) } }
    var arguments = strings + [nil]
    var child: pid_t = 0
    guard
        arguments.withUnsafeMutableBufferPointer({
            posix_spawn(&child, "/bin/sleep", nil, &attributes, $0.baseAddress, environ)
        }) == 0
    else { return 1 }
    do { try ExtensionNativeTask.registerChild(child) } catch {
        kill(-child, SIGKILL)
        return 1
    }
    try? Data(String(child).utf8).write(to: root.appendingPathComponent("native-child.pid"))
    if bytes[0] == 3 { return 9 }
    while true { usleep(100_000) }
}
