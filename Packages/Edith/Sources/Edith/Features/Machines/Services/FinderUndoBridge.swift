import AppKit
import EdithKit
import Foundation

@MainActor
enum FinderUndoBridge {
    private static var models: [UUID: [ObjectIdentifier: FinderModel]] = [:]
    private static var observer: NSObjectProtocol?

    static func register(_ model: FinderModel) {
        models[model.session.machine.id, default: [:]][ObjectIdentifier(model)] = model
        start()
    }

    static func forget(_ model: FinderModel) {
        models[model.session.machine.id]?.removeValue(forKey: ObjectIdentifier(model))
        if models[model.session.machine.id]?.isEmpty == true {
            models.removeValue(forKey: model.session.machine.id)
        }
    }

    static func undoable(machineID: UUID) -> FinderModel? {
        models[machineID]?.values.first { $0.canUndo }
    }

    static func start() {
        guard observer == nil else { return }
        observer = IPC.observe(
            IPC.Name.requestFinderUndo,
            info: { info in
                guard let raw = info["machine"] as? String, let id = UUID(uuidString: raw) else {
                    return
                }
                Task { @MainActor in
                    guard let model = undoable(machineID: id) else {
                        IPC.post(
                            IPC.Name.finderUndoResult,
                            userInfo: ["undone": false, "reason": "nothing to undo"])
                        return
                    }
                    let label = model.undoTitle ?? "the last change"
                    await model.undoLastOperation()
                    IPC.post(
                        IPC.Name.finderUndoResult,
                        userInfo: ["undone": true, "label": label])
                }
            })
    }
}
