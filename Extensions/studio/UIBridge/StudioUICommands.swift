import AppKit
import EdithExtensionSupport
import EdithStudio
import Foundation

@MainActor enum StudioUICommands {
    private static let fields: [String: Set<String>] = [
        "studio.ui.state": [],
        "studio.ui.facts": ["path"],
        "studio.ui.clearMissing": [],
        "studio.ui.thumbnail": ["path", "side"],
        "studio.ui.preview": ["toolID", "path", "settings"],
        "studio.ui.workflow.save": ["workflow"],
        "studio.ui.workflow.remove": ["id"],
        "studio.ui.project.trash": ["path"],
        "studio.ui.install": ["engine"],
        "studio.ui.paste": [],
        "studio.ui.preferences": ["mode", "folder"],
        "studio.ui.reveal": ["paths"],
        "studio.ui.open": ["path"],
        "studio.ui.job.start": ["id", "toolID", "paths", "settings"],
        "studio.ui.job.read": ["id"],
        "studio.ui.job.cancel": ["id"],
    ]

    static func execute(_ operation: String, payload: Data, model: StudioModel) async throws -> Data
    {
        try Task.checkCancellation()
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        guard let allowed = fields[operation], !payload.isEmpty,
            payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw ExtensionPeerError.invalidRequest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch operation {
        case "studio.ui.state":
            return try await snapshot(model)
        case "studio.ui.facts":
            guard let path = object["path"] as? String else {
                throw ExtensionPeerError.invalidRequest
            }
            let url = try StudioCommands.localPath(path)
            let facts = await StudioInspector.facts(for: url)
            try Task.checkCancellation()
            return try encoder.encode(StudioUIFileFacts(facts))
        case "studio.ui.clearMissing":
            let items = try StudioMediaLibrary.list(defaults: model.defaults)
            let missing = Set(
                items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.url))
            let remaining = try StudioMediaLibrary.remove(missing, defaults: model.defaults)
            model.refreshLibrary()
            return try encoder.encode(remaining)
        case "studio.ui.thumbnail":
            let url = try path(object)
            guard let side = object["side"] as? Double, side.isFinite, (1...640).contains(side)
            else {
                throw ExtensionPeerError.invalidRequest
            }
            let image = await StudioThumbnails.shared.thumbnail(for: url, side: side)
            let bytes = image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
            return try encoder.encode(bytes)
        case "studio.ui.preview":
            guard let id = object["toolID"] as? String, let tool = StudioCatalog.tool(id) else {
                throw ExtensionPeerError.invalidRequest
            }
            let settings: StudioSettings = try decode(object["settings"])
            let preview = try await StudioPreview.render(
                tool: tool, input: path(object),
                settings: settings, environment: model.environment)
            return try encoder.encode(StudioUIPreview(preview))
        case "studio.ui.workflow.save":
            let workflow: StudioWorkflow = try decode(object["workflow"])
            try workflow.validate()
            model.loadWorkflows()
            var values = StudioWorkflowStore.load()
            values.removeAll { $0.id == workflow.id }
            values.append(workflow)
            StudioWorkflowStore.save(values)
        case "studio.ui.workflow.remove":
            let id = try identifier(object)
            StudioWorkflowStore.save(StudioWorkflowStore.load().filter { $0.id != id })
        case "studio.ui.project.trash":
            _ = try await VideoEditorService.trashProject(path(object))
        case "studio.ui.install":
            guard let text = object["engine"] as? String,
                let engine = StudioEngine(rawValue: text)
            else { throw ExtensionPeerError.invalidRequest }
            model.install(engine)
        case "studio.ui.paste": model.paste()
        case "studio.ui.preferences":
            guard let mode = object["mode"] as? String,
                StudioDestinationMode(rawValue: mode) != nil,
                let folder = object["folder"] as? String
            else { throw ExtensionPeerError.invalidRequest }
            if !folder.isEmpty { _ = try StudioCommands.localPath(folder) }
            model.defaults.set(mode, forKey: AppStorageKeys.Studio.destination)
            model.defaults.set(folder, forKey: AppStorageKeys.Studio.folder)
        case "studio.ui.reveal":
            guard let paths = object["paths"] as? [String], !paths.isEmpty,
                paths.count <= StudioCommands.maximumPaths
            else { throw ExtensionPeerError.invalidRequest }
            await StudioFinderReveal.reveal(try paths.map(StudioCommands.localPath))
        case "studio.ui.open": StudioFinderReveal.open(try path(object))
        case "studio.ui.job.start":
            let id = try identifier(object)
            guard let toolID = object["toolID"] as? String,
                let tool = StudioCatalog.tool(toolID)
                    ?? StudioWorkflowStore.load().first(where: { $0.toolID == toolID })?.tool,
                let paths = object["paths"] as? [String],
                paths.count <= StudioCommands.maximumPaths,
                model.jobs.filter(\.isRunning).count < 12
            else { throw ExtensionPeerError.invalidRequest }
            let settings: StudioSettings = try decode(object["settings"])
            let inputs = try paths.map(StudioCommands.localPath)
            try StudioRunner.validate(tool: tool, inputs: inputs, settings: settings)
            let job: StudioJob
            if let existing = model.job(id) {
                guard !existing.isRunning, existing.tool.id == toolID else {
                    throw ExtensionPeerError.invalidRequest
                }
                existing.inputs = inputs
                existing.settings = settings
                job = existing
            } else {
                job = StudioJob(tool: tool, inputs: inputs, settings: settings, id: id)
                model.jobs.insert(job, at: 0)
                if model.jobs.count > 24 { model.jobs.removeAll { !$0.isRunning && $0.id != id } }
            }
            model.run(job)
            return try encoder.encode(StudioUIJobState(job))
        case "studio.ui.job.read":
            guard let job = model.job(try identifier(object)) else {
                throw ExtensionPeerError.invalidRequest
            }
            return try encoder.encode(StudioUIJobState(job))
        case "studio.ui.job.cancel":
            guard let job = model.job(try identifier(object)) else {
                throw ExtensionPeerError.invalidRequest
            }
            job.cancel()
        default: throw ExtensionPeerError.invalidRequest
        }
        return try await snapshot(model)
    }
    private static func decode<Value: Decodable>(_ object: Any?) throws -> Value {
        guard let object else { throw ExtensionPeerError.invalidRequest }
        return try JSONDecoder().decode(
            Value.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    private static func identifier(_ object: [String: Any]) throws -> UUID {
        guard let text = object["id"] as? String, let id = UUID(uuidString: text) else {
            throw ExtensionPeerError.invalidRequest
        }
        return id
    }

    private static func path(_ object: [String: Any]) throws -> URL {
        guard let path = object["path"] as? String else { throw ExtensionPeerError.invalidRequest }
        return try StudioCommands.localPath(path)
    }

    private static func snapshot(_ model: StudioModel) async throws -> Data {
        let files = try StudioMediaLibrary.list(defaults: model.defaults)
        var value = try await BlockingWork.perform {
            StudioUIState(
                files: files.filter { FileManager.default.fileExists(atPath: $0.url.path) },
                projects: VideoProject.listProjects().map(StudioUIState.Project.init),
                recent: StudioLibraryStore.loadRecent(), workflows: StudioWorkflowStore.load(),
                environment: StudioUIState.Environment(StudioEngineLocator.detect()))
        }
        try Task.checkCancellation()
        value.destinationMode =
            model.defaults.string(forKey: AppStorageKeys.Studio.destination)
            ?? StudioDestinationMode.original.rawValue
        value.destinationFolder = model.defaults.string(forKey: AppStorageKeys.Studio.folder) ?? ""
        value.installing = model.installing
        value.installLog = model.installLog
        value.message = model.message
        value.pendingOpen = VideoEditorOpenBridge.shared.pending?.request
        return try JSONEncoder().encode(value)
    }

}
