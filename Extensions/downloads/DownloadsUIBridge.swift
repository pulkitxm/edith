import EdithExtensionSupport
import Foundation

struct DownloadsToolsSnapshot: Codable {
    let installed: Set<String>
    let installing: String?
    let error: String?
}
struct DownloadsUIConfiguration: Codable {
    let tools: DownloadsToolsSnapshot
    let directories: [String: URL]
    let version: String?
    let kind: DownloadKind
}
struct DownloadsUIAction: Codable {
    let action: String
    var id: UUID? = nil
    var directory: URL? = nil
    var tool: String? = nil
    var kind: DownloadKind? = nil
}

@MainActor struct DownloadsUIBridge {
    let invoke: (String, Data) async throws -> Data
    init(client: ExtensionEngineClient) { invoke = { try await client.invoke($0, payload: $1) } }
    init(invoke: @escaping (String, Data) async throws -> Data) { self.invoke = invoke }

    func configuration() async throws -> DownloadsUIConfiguration {
        let data = try await invoke("downloads.ui.configuration", Data("{}".utf8))
        return try JSONDecoder().decode(DownloadsUIConfiguration.self, from: data)
    }
    func update() async throws -> DownloadToolUpdate {
        let data = try await invoke("downloads.ui.update", Data("{}".utf8))
        return try JSONDecoder().decode(DownloadToolUpdate.self, from: data)
    }
    func perform(_ action: DownloadsUIAction) async throws {
        _ = try await invoke("downloads.ui.action", JSONEncoder().encode(action))
    }
    static func execute(_ command: String, payload: Data, worker: DownloadsWorker) async throws
        -> Data
    {
        guard !worker.stopped, payload.count <= 8192 else { throw ExtensionPeerError.unavailable }
        let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        switch command {
        case "downloads.ui.configuration":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            if !fixture { worker.downloader.tools.refresh() }
            let executable = fixture ? nil : CLIToolEnvironment.executable(named: "yt-dlp")
            let status = await DownloadToolOperationExecution.status(executable: executable)
            return try JSONEncoder().encode(
                DownloadsUIConfiguration(
                    tools: worker.downloader.tools.snapshot,
                    directories: Dictionary(
                        uniqueKeysWithValues: DownloadKind.allCases.map {
                            ($0.rawValue, MediaDownloadInput.defaultDirectory(for: $0))
                        }), version: status.version,
                    kind: DownloadKind(
                        rawValue: SharedDefaults.store.string(
                            forKey: AppStorageKeys.Music.downloadKind) ?? "") ?? .post))
        case "downloads.ui.update":
            guard !fixture, payload == Data("{}".utf8) else {
                throw ExtensionPeerError.invalidRequest
            }
            return try JSONEncoder().encode(
                try await DownloadToolOperationExecution.update(
                    executable: CLIToolEnvironment.executable(named: "yt-dlp")))
        case "downloads.ui.action":
            let action = try JSONDecoder().decode(DownloadsUIAction.self, from: payload)
            switch action.action {
            case "kind":
                guard let kind = action.kind else { throw ExtensionPeerError.invalidRequest }
                SharedDefaults.store.set(kind.rawValue, forKey: AppStorageKeys.Music.downloadKind)
            case "open", "reveal":
                guard !fixture, let id = action.id else { throw ExtensionPeerError.invalidRequest }
                _ = try await worker.execute(
                    "downloads." + action.action, payload: JSONEncoder().encode(id))
            case "audioFolder":
                guard let directory = action.directory, directory.isFileURL else {
                    throw ExtensionPeerError.invalidRequest
                }
                if let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] {
                    let root = URL(fileURLWithPath: path).standardizedFileURL
                        .resolvingSymlinksInPath()
                    let chosen = directory.standardizedFileURL.resolvingSymlinksInPath()
                    guard chosen == root || chosen.path.hasPrefix(root.path + "/") else {
                        throw ExtensionPeerError.invalidRequest
                    }
                }
                DownloadsStorage.setAudioDirectory(directory)
            case "install":
                guard !fixture, let tool = action.tool, DownloadsTools.names.contains(tool) else {
                    throw ExtensionPeerError.invalidRequest
                }
                worker.downloader.tools.install(tool)
            default: throw ExtensionPeerError.invalidRequest
            }
            try Task.checkCancellation()
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
