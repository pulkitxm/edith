import CryptoKit
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
            import ctypes,hashlib,json,os,select,struct,sys,time
            args=sys.argv[1:]
            home=os.environ['EDITH_EXTENSION_FIXTURE_HOME']
            project=os.path.join(home,'synthetic-project')
            tree={'path':project,'head':'1234567890abcdef','branch':'main','current':True,'bare':False,'detached':False,'locked':None,'prunable':None}
            if 'tui' in args:
                layout=struct.Struct('=12I16s32s6I2Q')
                library=ctypes.CDLL('/usr/lib/libproc.dylib')
                library.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
                library.proc_pidinfo.restype=ctypes.c_int
                buffer=ctypes.create_string_buffer(layout.size)
                if library.proc_pidinfo(os.getpid(),3,0,buffer,layout.size)!=layout.size: raise RuntimeError('Missing own birth identity')
                info=layout.unpack(buffer.raw)
                library.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
                library.proc_pidpath.restype=ctypes.c_int
                executable=ctypes.create_string_buffer(4096)
                if library.proc_pidpath(os.getpid(),executable,4096)<=0: raise RuntimeError('Missing own executable identity')
                script=os.path.realpath(__file__)
                receipt={'pid':os.getpid(),'birth':str(info[-2])+'.'+str(info[-1]),'parent':os.getppid(),'group':os.getpgrp(),'inputTerminal':os.isatty(0),'executable':os.path.realpath(executable.value.decode()),'script':script,'scriptSHA256':hashlib.sha256(open(script,'rb').read()).hexdigest(),'tabID':os.environ['EDITH_QUINJET_TAB_ID']}
                receiptPath=os.path.join(home,'quinjet-tool-receipt.json')
                descriptor=os.open(receiptPath,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
                with os.fdopen(descriptor,'w') as output: json.dump(receipt,output)
                os.write(1,b'synthetic review ready\\r\\n')
                time.sleep(0.5)
                os.write(1,b'\\x1b]6973;quinjet;open-new-tab\\x07')
                deadline=time.monotonic()+120
                while time.monotonic()<deadline:
                    if select.select([0],[],[],0.1)[0]:
                        value=os.read(0,4096)
                        if not value: break
                        os.write(1,b'synthetic-input:'+value)
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
        let home = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let receipt = home.appendingPathComponent("quinjet-tool-receipt.json")
        try? FileManager.default.removeItem(at: receipt)
        let script = home.appendingPathComponent("bin/quinjet")
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            attributes[.ownerAccountID] as? UInt32 == getuid(),
            attributes[.posixPermissions] as? Int == 0o700
        else { throw HostWorkerError.invalidResponse }
        let scriptSHA256 = SHA256.hash(data: try Data(contentsOf: script)).map {
            String(format: "%02x", $0)
        }.joined()
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
        let pid = try await QuinjetLifecycleFixture.verify(
            invoke: { try await endpoint.invoke($0, payload: $1) }, workerPID: workerPID,
            script: script.path, scriptSHA256: scriptSHA256,
            receipt: {
                guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }
                let attributes = try FileManager.default.attributesOfItem(atPath: receipt.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                    attributes[.ownerAccountID] as? UInt32 == getuid(),
                    attributes[.posixPermissions] as? Int == 0o600,
                    (attributes[.size] as? Int ?? Int.max) <= 8192
                else { throw HostWorkerError.invalidResponse }
                return try Data(contentsOf: receipt)
            }, process: QuinjetLifecycleFixture.process)
        let request = SurfaceSnapshotRequest(target: .notch, tile: .init(.ability("quinjet")))
        let snapshot = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.snapshot", payload: request.encoded(providerID: "quinjet")),
            providerID: "quinjet")
        guard snapshot.rows.count == 2,
            snapshot.rows.contains(where: { $0.title == "Synthetic review · main" })
        else { throw HostWorkerError.invalidResponse }
        return [pid]
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostWorkerError.invalidResponse
        }
        return object
    }
}
