import AppKit
import EdithExtensionUI
import EdithExtensionSupport
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CodeStatsPNGDelivery: Codable { let data: Data; let name: String; let save: Bool }

@MainActor struct CodeStatsExportDelivery {
    static let maximumBytes = 4 * 1024 * 1024
    let chooseSaveURL: (String) async throws -> URL?
    let copy: (Data) throws -> Void
    var write: (Data, URL) throws -> Void = ExportDelivery.write

    static var live: Self {
        Self(
            chooseSaveURL: { name in
                guard CodeStatsExecutionEnvironment.fixtureHome == nil else {
                    throw ExtensionPeerError.invalidRequest
                }
                return await ExportDelivery.chooseSaveURL(suggestedName: name, in: nil)
            },
            copy: { data in
                guard CodeStatsExecutionEnvironment.fixtureHome == nil else {
                    throw ExtensionPeerError.invalidRequest
                }
                try ExportDelivery.copyPNG(data)
            })
    }

    func deliver(_ request: CodeStatsPNGDelivery) async throws -> String {
        try Task.checkCancellation()
        guard request.name.hasSuffix(".png"), request.name.utf8.count <= 128,
            !request.name.contains("/"), !request.name.contains("\\"),
            !request.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            request.data.count <= Self.maximumBytes,
            request.data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
            let source = CGImageSourceCreateWithData(request.data as CFData, nil),
            CGImageSourceGetType(source) as String? == UTType.png.identifier,
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...4096).contains(width), (1...4096).contains(height),
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { throw ExtensionPeerError.invalidRequest }
        if request.save {
            let url = try await chooseSaveURL(request.name)
            try Task.checkCancellation()
            guard let url else { return "Save cancelled" }
            try write(request.data, url)
            return "Saved to " + url.lastPathComponent
        }
        try Task.checkCancellation()
        try copy(request.data)
        return "Image copied"
    }
}

struct CodeStatsUIPreferences: Codable {
    let identity: CodeStatsIdentity
    let schedule: CodeStatsSchedule
    let includeForks: Bool
    let includeArchived: Bool
}

struct CodeStatsUIBridge: Sendable {
    let invoke: @MainActor @Sendable (String, Data) async throws -> Data
    @MainActor init(client: ExtensionEngineClient) {
        invoke = { try await client.invoke($0, payload: $1) }
    }
    init(invoke: @escaping @MainActor @Sendable (String, Data) async throws -> Data) {
        self.invoke = invoke
    }

    @MainActor private func read<T: Decodable>(
        _ operation: String, payload: Data = Data("{}".utf8), as: T.Type = T.self
    ) async throws -> T {
        let data = try await invoke("codeStats.ui." + operation, payload)
        return try JSONDecoder().decode(T.self, from: data)
    }
    @MainActor var service: CodeStatsPageService {
        .init(
            status: { try await read("status") },
            report: { range in
                try await read("report", payload: JSONEncoder().encode(CodeStatsReportQuery(range)))
            },
            facts: { try await read("facts") }, start: { try await read("start") },
            cancel: { try await read("cancel") }, profile: { try await read("profile") },
            authors: { try await read("authors") },
            updates: {
                AsyncStream { continuation in
                    let task = Task {
                        do {
                            while !Task.isCancelled {
                                let status: CodeStatsStatus = try await read("status")
                                continuation.yield(status)
                                try await Task.sleep(for: .seconds(1))
                            }
                        } catch {}
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
    }
    @MainActor func deliver(_ data: Data, name: String, save: Bool) async throws -> String {
        let request = CodeStatsPNGDelivery(data: data, name: name, save: save)
        return try await read("export", payload: JSONEncoder().encode(request))
    }
    @MainActor func folder(_ path: String) async throws {
        _ = try await invoke("codeStats.ui.folder", JSONEncoder().encode(path))
    }
    @MainActor func settings(_ defaults: UserDefaults) async throws {
        let request = CodeStatsUIPreferences(
            identity: CodeStatsPreferences.identity(in: defaults),
            schedule: CodeStatsPreferences.schedule(in: defaults),
            includeForks: defaults.bool(forKey: AppStorageKeys.CodeStats.includeForks),
            includeArchived: defaults.object(forKey: AppStorageKeys.CodeStats.includeArchived)
                as? Bool ?? true)
        _ = try await invoke("codeStats.ui.settings", JSONEncoder().encode(request))
    }
    @MainActor static func execute(
        _ command: String, payload: Data, workflow: CodeStatsWorkflow,
        exportDelivery: CodeStatsExportDelivery? = nil
    ) async throws -> Data {
        guard payload.count <= ExtensionEngineWire.maximumPayloadBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        switch command {
        case "codeStats.ui.status", "codeStats.ui.facts", "codeStats.ui.start",
            "codeStats.ui.cancel", "codeStats.ui.profile", "codeStats.ui.authors":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            let operation: String
            switch command {
            case "codeStats.ui.status": operation = CodeStatsCommand.status
            case "codeStats.ui.facts": operation = CodeStatsCommand.facts
            case "codeStats.ui.start": operation = CodeStatsCommand.start
            case "codeStats.ui.cancel": operation = CodeStatsCommand.cancel
            case "codeStats.ui.profile": operation = CodeStatsCommand.profile
            default: operation = CodeStatsCommand.authors
            }
            return try await workflow.perform(operation: operation, payload: Data())
        case "codeStats.ui.report":
            let request = try JSONDecoder().decode(CodeStatsReportQuery.self, from: payload)
            return try await workflow.perform(
                operation: CodeStatsCommand.report, payload: JSONEncoder().encode(request))
        case "codeStats.ui.folder":
            let path = try JSONDecoder().decode(String.self, from: payload)
            guard !path.isEmpty, path.utf8.count <= 4096 else {
                throw ExtensionPeerError.invalidRequest
            }
            if let fixture = CodeStatsExecutionEnvironment.fixtureHome {
                let url = CodeStatsPaths.standardizedURL(path, homeDirectory: fixture)
                guard url == fixture || url.path.hasPrefix(fixture.path + "/") else {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            let value = try CodeStatsPreferences.selectFolder(
                path, homeDirectory: CodeStatsExecutionEnvironment.home)
            await workflow.settingsChanged()
            return try JSONEncoder().encode(value)
        case "codeStats.ui.export":
            let request = try JSONDecoder().decode(CodeStatsPNGDelivery.self, from: payload)
            return try JSONEncoder().encode(try await (exportDelivery ?? .live).deliver(request))
        case "codeStats.ui.settings":
            let request = try JSONDecoder().decode(CodeStatsUIPreferences.self, from: payload)
            switch request.schedule {
            case .manual: break
            case .daily(let hour):
                guard (0...23).contains(hour) else { throw ExtensionPeerError.invalidRequest }
            case .weekly(let weekday, let hour):
                guard (1...7).contains(weekday), (0...23).contains(hour) else {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            CodeStatsPreferences.setIdentity(request.identity, in: SharedDefaults.store)
            CodeStatsPreferences.setSchedule(request.schedule, in: SharedDefaults.store)
            SharedDefaults.store.set(
                request.includeForks, forKey: AppStorageKeys.CodeStats.includeForks)
            SharedDefaults.store.set(
                request.includeArchived, forKey: AppStorageKeys.CodeStats.includeArchived)
            await workflow.settingsChanged()
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
