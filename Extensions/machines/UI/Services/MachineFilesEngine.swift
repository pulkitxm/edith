import Foundation

@MainActor final class MachineFilesEngine {
    private var models: [UUID: FinderModel] = [:]
    private let session: (UUID) throws -> MachineSession
    private var stopped = false

    init(session: @escaping (UUID) throws -> MachineSession) { self.session = session }

    func execute(_ request: MachineFileRequest) async throws -> MachineFileState {
        try request.validate()
        guard !stopped, models.count < 64 || models[request.viewID] != nil else {
            throw MachineUIError.unavailable
        }
        let model: FinderModel
        if let retained = models[request.viewID] {
            guard retained.session.id == request.machineID else {
                throw MachineUIError.invalidRequest
            }
            model = retained
        } else {
            model = FinderModel(session: try session(request.machineID), path: request.path)
            models[request.viewID] = model
        }
        model.path = request.path
        model.selection = request.selection
        model.errorMessage = nil
        switch request.operation {
        case .load: await model.load()
        case .places: await model.loadPlaces()
        case .home:
            model.path = try await model.session.homeDirectory().get()
            await model.load()
        case .measure:
            guard let entry = model.entries.first(where: { $0.path == request.text }) else {
                throw MachineUIError.invalidRequest
            }
            await model.measure(entry)
        case .open:
            guard let entry = model.entries.first(where: { $0.path == request.text }) else {
                throw MachineUIError.invalidRequest
            }
            if entry.isDirectory {
                model.navigate(to: entry.path); await model.load()
            } else {
                await model.openOwnedFile(entry)
            }
        case .reveal: await model.revealInFinder()
        case .undo: await model.undoLastOperation()
        case .rename:
            model.renaming = request.paths.first; model.renameText = request.text
            await model.commitRename()
        case .mkdir: await model.newFolder()
        case .duplicate: await model.duplicate(paths: request.paths)
        case .trash: await model.trashSelection(permanently: request.permanently)
        case .download:
            guard request.text.hasPrefix("/") else { throw MachineUIError.invalidRequest }
            await model.download(to: URL(fileURLWithPath: request.text))
        case .upload:
            guard request.paths.allSatisfy({ $0.hasPrefix("/") }) else {
                throw MachineUIError.invalidRequest
            }
            await model.upload(request.paths.map { URL(fileURLWithPath: $0) })
        case .search:
            model.searchQuery = request.text
            await model.runOwnedSearch()
        case .drop:
            guard let intent = request.intent else { throw MachineUIError.invalidRequest }
            await model.perform(intent: intent, destination: request.text)
        case .commitDrop:
            guard let intent = request.intent else { throw MachineUIError.invalidRequest }
            await model.commit(
                intent: intent, destination: request.text, resolutions: request.resolutions)
        case .cancel: model.cancelTransfer(); model.stopLoading()
        case .release:
            model.cancelTransfer(); model.stopLoading()
            FinderUndoBridge.forget(model)
            models.removeValue(forKey: request.viewID)
        }
        try Task.checkCancellation()
        guard !stopped else { throw MachineUIError.unavailable }
        return model.fileState()
    }

    func undo(machineID: UUID) async throws -> [String: Any] {
        guard !stopped,
            let model = models.values.first(where: { $0.session.id == machineID && $0.canUndo })
        else { return ["undone": false] }
        let label = model.undoTitle ?? "the last change"
        await model.undoLastOperation()
        if let error = model.errorMessage { throw MachineUIFailure(message: error) }
        return ["undone": true, "label": label]
    }

    func shutdown() {
        stopped = true
        for model in models.values {
            model.cancelTransfer(); model.stopLoading(); FinderUndoBridge.forget(model)
        }
        models = [:]
    }
}
