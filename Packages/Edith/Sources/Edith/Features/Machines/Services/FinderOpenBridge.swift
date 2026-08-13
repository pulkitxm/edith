import AppKit
import EdithKit
import Foundation

@MainActor
enum FinderOpenBridge {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = IPC.observe(
            IPC.Name.requestFinderOpen,
            info: { info in
                guard let raw = info["machine"] as? String, let id = UUID(uuidString: raw) else {
                    return
                }
                let path = info["path"] as? String
                Task { @MainActor in open(machineID: id, path: path) }
            })
    }

    static func open(machineID: UUID, path: String?) {
        let model = MachinesModel.shared
        guard model.store.machines.contains(where: { $0.id == machineID }) else {
            IPC.post(
                IPC.Name.finderOpenResult,
                userInfo: ["opened": false, "reason": "no such machine"])
            return
        }
        let session = model.session(for: machineID)
        session.start()
        FinderWindow.open(session: session, path: path)
        IPC.post(
            IPC.Name.finderOpenResult,
            userInfo: ["opened": true, "path": path ?? "", "machine": session.machine.name])
    }
}
