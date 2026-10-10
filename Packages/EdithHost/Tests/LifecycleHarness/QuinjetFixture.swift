import Darwin
import EdithExtensionSupport
import EdithHostCore
import Foundation

enum QuinjetFixture {
    static func prepare() throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] else {
            throw HostWorkerError.rejected
        }
        let home = URL(fileURLWithPath: path)
        let bin = home.appendingPathComponent("bin")
        let project = home.appendingPathComponent("synthetic-project")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let script = """
            #!/usr/bin/python3
            import json,os,sys,time
            args=sys.argv[1:]
            home=os.environ['EDITH_EXTENSION_FIXTURE_HOME']
            project=os.path.join(home,'synthetic-project')
            tree={'path':project,'head':'1234567890abcdef','branch':'main','current':True,'bare':False,'detached':False,'locked':None,'prunable':None}
            if 'tui' in args:
                open(os.path.join(home,'quinjet-pty.pid'),'w').write(str(os.getpid()))
                os.write(1,b'synthetic review ready\\r\\n')
                time.sleep(0.5)
                os.write(1,b'\\x1b]6973;quinjet;open-new-tab\\x07')
                time.sleep(120)
            elif 'capabilities' in args:
                print(json.dumps({'commands':[{'path':'quinjet tui','arguments':[{'id':'theme','possibleValues':['quinjet','github']}]}]}))
            elif 'worktree' in args:
                print(json.dumps([tree]))
            elif 'status' in args:
                print(json.dumps({'changes':[]}))
            else:
                print(json.dumps([{'name':'Synthetic review','commonDir':project+'/.git','worktrees':[tree]}]))
            """
        let executable = bin.appendingPathComponent("quinjet")
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
        let pidFile = URL(fileURLWithPath: path).appendingPathComponent("quinjet-pty.pid")
        try? FileManager.default.removeItem(at: pidFile)
        let projects = try object(
            await endpoint.invoke("quinjet.projects", payload: Data("{}".utf8)))
        guard let project = (projects["projects"] as? [[String: String]])?.first?["id"] else {
            throw NSError(
                domain: "QuinjetFixture", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Missing projects: " + String(describing: projects)
                ])
        }
        let trees = try object(
            await endpoint.invoke(
                "quinjet.worktrees",
                payload: JSONSerialization.data(withJSONObject: ["projectID": project])))
        guard let tree = (trees["worktrees"] as? [[String: String]])?.first?["id"] else {
            throw NSError(
                domain: "QuinjetFixture", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Missing worktrees: " + String(describing: trees)
                ])
        }
        _ = try await endpoint.invoke(
            "quinjet.launch", payload: JSONSerialization.data(withJSONObject: ["worktreeID": tree]))
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8),
                let pid = Int32(value), pid > 1, kill(pid, 0) == 0
            {
                let sessions = try object(
                    await endpoint.invoke("quinjet.session.sessions", payload: Data("{}".utf8)))
                if (sessions["sessions"] as? [[String: Any]])?.count == 2 {
                    let request = SurfaceSnapshotRequest(
                        target: .notch, tile: .init(.ability("quinjet")))
                    let snapshot = try SurfaceSnapshot.decode(
                        await endpoint.invoke(
                            "surface.snapshot", payload: request.encoded(providerID: "quinjet")),
                        providerID: "quinjet")
                    guard snapshot.rows.count == 2,
                        snapshot.rows.contains(where: { $0.title == "Synthetic review · main" })
                    else {
                        throw NSError(
                            domain: "QuinjetFixture", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Invalid current review surface: "
                                    + String(describing: snapshot)
                            ])
                    }
                    return [pid, try nativeProcess(in: path, workerPID: workerPID)]
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let sessions = try await endpoint.invoke(
            "quinjet.session.sessions", payload: Data("{}".utf8))
        let receipt =
            (try? String(
                contentsOf: URL(fileURLWithPath: path)
                    .appendingPathComponent("quinjet-native-receipt.json"), encoding: .utf8))
            ?? "No native entry receipt"
        throw NSError(
            domain: "QuinjetFixture", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Terminal did not start or deliver the managed action: "
                    + String(decoding: sessions, as: UTF8.self) + " " + receipt
            ])
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostWorkerError.invalidResponse
        }
        return object
    }
    private static func nativeProcess(in path: String, workerPID: Int32) throws -> Int32 {
        let receipt = try Data(
            contentsOf: URL(fileURLWithPath: path)
                .appendingPathComponent("quinjet-native-receipt.json"))
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
