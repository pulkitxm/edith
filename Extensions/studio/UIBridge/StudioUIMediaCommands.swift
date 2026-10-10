import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithStudio
import Foundation

@MainActor enum StudioUIMediaCommands {
    private static let fields: [String: Set<String>] = [
        "studio.ui.media.read": ["path"], "studio.ui.media.write": ["path", "resource"],
        "studio.ui.media.waveform": ["path"], "studio.ui.media.beats": ["path", "settings"],
        "studio.ui.media.aspect": ["path"], "studio.ui.media.duration": ["path"],
        "studio.ui.media.frameSampling": ["project"],
        "studio.ui.media.scan": ["resource", "type"],
    ]
    static func execute(
        _ operation: String, payload: Data, resources: StudioUIResources,
        work: StudioUILongOperations
    ) async throws -> Data {
        guard let allowed = fields[operation], payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        switch operation {
        case "studio.ui.media.read":
            let url = try path(object)
            let data = try await BlockingWork.perform {
                let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let count = size.fileSize,
                    count <= 128 * 1024 * 1024
                else { throw ExtensionPeerError.invalidRequest }
                return try Data(contentsOf: url)
            }
            try Task.checkCancellation()
            guard data.count <= 128 * 1024 * 1024 else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(resources.store(data))
        case "studio.ui.media.write":
            let url = try path(object)
            let data = try consume(object["resource"], resources: resources)
            guard data.count <= 128 * 1024 * 1024 else { throw ExtensionPeerError.invalidRequest }
            try await BlockingWork.perform { try data.write(to: url, options: .atomic) }
            return Data("{}".utf8)
        case "studio.ui.media.waveform":
            let url = try path(object)
            return try encoder.encode(
                work.start { _ in
                    try encoder.encode(await VideoWaveformCache.shared.envelope(url))
                })
        case "studio.ui.media.beats":
            let url = try path(object)
            let settings = try JSONDecoder().decode(
                VideoBeatAnalysis.Settings.self,
                from: JSONSerialization.data(withJSONObject: object["settings"] ?? NSNull()))
            try settings.validate()
            return try encoder.encode(
                work.start { _ in
                    try encoder.encode(await VideoBeatAnalysis.analyze(url, settings: settings))
                })
        case "studio.ui.media.duration":
            let asset = AVURLAsset(url: try path(object))
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= 0 else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(duration)
        case "studio.ui.media.aspect":
            let url = try path(object)
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExtensionPeerError.invalidRequest
            }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let size = natural.applying(transform)
            guard size.height != 0 else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(abs(size.width / size.height))
        case "studio.ui.media.frameSampling":
            let data = try consume(object["project"], resources: resources)
            let project = try JSONDecoder().decode(StudioUIVideoProject.self, from: data).value
            for url in VideoEditorService.sourceURLs(project, includeSidecars: false) {
                _ = try StudioCommands.localPath(url.path)
            }
            return try encoder.encode(
                work.start { _ in
                    try await project.validateFrameSampling()
                    return Data("{}".utf8)
                })
        case "studio.ui.media.scan":
            let data = try consume(object["resource"], resources: resources)
            guard data.count <= 128 * 1024 * 1024, let type = object["type"] as? String,
                ["pdf", "png", "jpg", "heic", "tiff"].contains(type)
            else { throw ExtensionPeerError.invalidRequest }
            let url = try await BlockingWork.perform {
                var bytes = data; var suffix = type
                if type == "tiff" {
                    guard let image = NSBitmapImageRep(data: data),
                        let jpeg = image.representation(
                            using: .jpeg, properties: [.compressionFactor: 0.9])
                    else { throw ExtensionPeerError.invalidRequest }
                    bytes = jpeg; suffix = "jpg"
                }
                return try StudioLibraryStore.saveToInbox(
                    bytes,
                    name: "\(type == "pdf" ? "Scan" : "Photo") \(UUID().uuidString).\(suffix)")
            }
            return try encoder.encode([url])
        default: throw ExtensionPeerError.invalidRequest
        }
    }
    private static func path(_ object: [String: Any]) throws -> URL {
        guard let path = object["path"] as? String else { throw ExtensionPeerError.invalidRequest }
        return try StudioCommands.localPath(path)
    }
    private static func consume(_ value: Any?, resources: StudioUIResources) throws -> Data {
        guard let value else { throw ExtensionPeerError.invalidRequest }
        return try resources.consume(
            JSONDecoder().decode(
                StudioUIResource.self, from: JSONSerialization.data(withJSONObject: value)))
    }
}

extension StudioUIFacade {
    func readFile(_ url: URL) async throws -> Data {
        let resource: StudioUIResource = try await read(
            "studio.ui.media.read", object: ["path": url.path])
        return try await downloadData(resource)
    }
    func writeFile(_ data: Data, to url: URL) async throws {
        let resource = try await uploadData(data)
        let _: [String: String] = try await read(
            "studio.ui.media.write", object: ["path": url.path, "resource": try object(resource)])
    }
}

extension VideoEditorModel {
    func readRemoteFile(_ url: URL, receive: @escaping @MainActor (Data) throws -> Void) {
        guard let facade else { return }
        runRemoteFile {
            let bytes = try await facade.readFile(url)
            try receive(bytes)
        }
    }
    func writeRemoteFile(_ data: Data, to url: URL) {
        guard let facade else { return }
        runRemoteFile { try await facade.writeFile(data, to: url) }
    }
}
