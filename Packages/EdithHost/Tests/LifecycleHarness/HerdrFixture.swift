import Darwin
import EdithExtensionSupport
import EdithHostCore
import Foundation

enum HerdrFixture {
    static func prepare() throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] else {
            throw HostWorkerError.rejected
        }
        let home = URL(fileURLWithPath: path)
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
            #!/usr/bin/python3
            import json,os,sys,time
            args=sys.argv[1:]
            open(os.path.join(os.environ['EDITH_EXTENSION_FIXTURE_HOME'],'herdr-invocations.jsonl'),'a').write(json.dumps(args)+'\\n')
            if args[:2]==['session','list']:
                print(json.dumps([{'name':'fixture'}]))
            elif 'attach' in args and 'terminal' in args:
                open(os.path.join(os.environ['EDITH_EXTENSION_FIXTURE_HOME'],'herdr-pty.pid'),'w').write(str(os.getpid()))
                os.write(1,b'synthetic terminal ready\\r\\n')
                time.sleep(120)
            elif 'get' in args:
                print(json.dumps({'result':{'pane':{'pane_id':'mock-pane','terminal_id':'mock-terminal'}}}))
            elif 'snapshot' in args:
                print('{}')
            else:
                print(json.dumps({'agents':[{'pane_id':'mock-pane','agent':'opencode','agent_status':'working','title':'Synthetic agent','workspace':'Mock workspace','cwd':'/tmp/mock-project'}]}))
            """
        let executable = bin.appendingPathComponent("herdr")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    @MainActor static func verify(_ endpoint: ExtensionPeerEndpoint, workerPID: Int32) async throws
        -> [Int32]
    {
        guard let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] else {
            throw HostWorkerError.rejected
        }
        let pidFile = URL(fileURLWithPath: path).appendingPathComponent("herdr-pty.pid")
        try? FileManager.default.removeItem(at: pidFile)
        _ = try await endpoint.invoke("herdr.refresh", payload: Data("{}".utf8))
        let request = SurfaceSnapshotRequest(target: .notch, tile: .init(.ability("herdr")))
        let snapshot = try SurfaceSnapshot.decode(
            try await endpoint.invoke(
                "surface.snapshot", payload: request.encoded(providerID: "herdr")),
            providerID: "herdr")
        guard snapshot.rows.count == 1, snapshot.rows.first?.title == "Synthetic agent",
            snapshot.sources.contains(where: { $0.id == "opencode" }),
            snapshot.rows.first?.sourceID == "opencode",
            let action = snapshot.rows.first?.actions.first?.id,
            UUID(uuidString: action) != nil
        else { throw HostWorkerError.invalidResponse }
        _ = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(snapshot: request, actionID: action).encoded(
                providerID: "herdr"))
        _ = try await endpoint.invoke(
            "herdr.terminal.open", payload: Data(#"{"agentID":"local|fixture|mock-pane"}"#.utf8))
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8),
                let pid = Int32(value), pid > 1, kill(pid, 0) == 0
            {
                return [pid, try nativeProcess(in: path, workerPID: workerPID)]
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let status = try await endpoint.invoke(
            "herdr.terminal.status", payload: Data(#"{"agentID":"local|fixture|mock-pane"}"#.utf8))
        throw NSError(
            domain: "HerdrFixture", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: String(decoding: status, as: UTF8.self) + " "
                    + ((try? String(
                        contentsOf: URL(fileURLWithPath: path).appendingPathComponent(
                            "herdr-invocations.jsonl"), encoding: .utf8)) ?? "No fixture invocation")
                    + " "
                    + ((try? String(
                        contentsOf: URL(fileURLWithPath: path).appendingPathComponent(
                            "herdr-native-receipt.json"), encoding: .utf8))
                        ?? "No native entry receipt")
                    + " "
                    + ((try? String(
                        contentsOf: URL(fileURLWithPath: path)
                            .appendingPathComponent("herdr-pty-receipt.json"), encoding: .utf8))
                        ?? "No PTY configuration receipt")

            ])
    }
    private static func nativeProcess(in path: String, workerPID: Int32) throws -> Int32 {
        let receipt = try Data(
            contentsOf: URL(fileURLWithPath: path)
                .appendingPathComponent("herdr-native-receipt.json"))
        guard let object = try JSONSerialization.jsonObject(with: receipt) as? [String: Any],
            let pid = object["pid"] as? Int32, pid > 1,
            object["owner"] as? Int32 == workerPID, pid != workerPID,
            let parent = object["parent"] as? Int32, parent > 0, parent != workerPID,
            object["group"] as? Int32 == pid,
            object["inputTerminal"] as? Int32 == 1, kill(pid, 0) == 0,
            executablePath(pid) == executablePath(workerPID), executablePath(pid) != nil
        else {
            throw NSError(
                domain: "NativeTerminalFixture", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid reparented native task: "
                        + String(decoding: receipt, as: UTF8.self)
                ])
        }
        return pid
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

}
