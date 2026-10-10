import AppKit
import EdithExtensionSupport
import EdithStudio
import Foundation

struct StudioUIImageData: Codable, Sendable {
    let pixels: Data
    let originalSize: CGSize?

    init(_ image: CGImage, originalSize: CGSize? = nil) throws {
        guard
            let pixels = NSBitmapImageRep(cgImage: image).representation(
                using: .png, properties: [:])
        else { throw StudioError.failed("The image preview could not be encoded.") }
        self.pixels = pixels
        self.originalSize = originalSize
    }

    var image: CGImage? {
        NSImage(data: pixels)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

struct StudioUIImageRender: Codable, Sendable {
    let preview: StudioUIImageData
    let geometry: StudioUIImageData?
}

@MainActor enum StudioUIImageCommands {
    private static let fields: [String: Set<String>] = [
        "studio.ui.image.load": ["path", "size"],
        "studio.ui.image.render": ["document", "size", "geometry"],
        "studio.ui.image.thumbnails": ["document"],
        "studio.ui.image.faces": ["document"],
        "studio.ui.image.export": ["document", "output"],
    ]

    static func execute(
        _ operation: String, payload: Data, model: StudioModel,
        resources: StudioUIResources, work: StudioUILongOperations
    ) async throws -> Data {
        try await StudioUILongOperations.scoped(payload: payload) { body in
            try await executeBody(
                operation, payload: body, model: model, resources: resources, work: work)
        }
    }

    private static func executeBody(
        _ operation: String, payload: Data, model: StudioModel,
        resources: StudioUIResources, work: StudioUILongOperations
    ) async throws -> Data {
        guard !model.isStopped, let allowed = fields[operation],
            payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        if operation == "studio.ui.image.load" {
            guard let path = object["path"] as? String else {
                throw ExtensionPeerError.invalidRequest
            }
            let url = try StudioCommands.localPath(path)
            let image = try await BlockingWork.perform {
                let source = try StudioImageEditorWork.loadSource(
                    url,
                    maxPixelSize: StudioImageEditorModel.previewSize
                ).get()
                return try StudioUIImageData(source.image, originalSize: source.originalSize)
            }
            return try encoder.encode(resources.store(encoder.encode(image)))
        }
        guard let value = object["document"] else { throw ExtensionPeerError.invalidRequest }
        let handle = try JSONDecoder().decode(
            StudioUIResource.self,
            from: JSONSerialization.data(withJSONObject: value))
        let data = try resources.consume(handle)
        guard data.count <= StudioCommands.maximumRequestBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        let document = try JSONDecoder().decode(ImageEditDocument.self, from: data)
        _ = try StudioCommands.localPath(document.sourcePath)
        for layer in document.layers {
            if case let .image(path) = layer.content { _ = try StudioCommands.localPath(path) }
        }
        switch operation {
        case "studio.ui.image.render":
            guard let size = object["size"] as? Int,
                (1...StudioImageEditorModel.previewSize).contains(size),
                let geometry = object["geometry"] as? Bool
            else { throw ExtensionPeerError.invalidRequest }
            let result = try await BlockingWork.perform {
                let source = try StudioImageEditorWork.loadSource(
                    document.sourceURL,
                    maxPixelSize: StudioImageEditorModel.previewSize
                ).get()
                let images = try StudioImageEditorWork.render(
                    document, source: source,
                    size: size, geometry: geometry
                ).get()
                return try StudioUIImageRender(
                    preview: StudioUIImageData(images.preview),
                    geometry: images.geometry.map { try StudioUIImageData($0) })
            }
            return try encoder.encode(resources.store(encoder.encode(result)))
        case "studio.ui.image.thumbnails":
            let images = try await BlockingWork.perform {
                let source = try StudioImageEditorWork.loadSource(
                    document.sourceURL,
                    maxPixelSize: StudioImageEditorModel.previewSize
                ).get()
                return try StudioImageEditorWork.filterThumbnails(document, source: source)
                    .reduce(into: [String: StudioUIImageData]()) {
                        $0[$1.key.rawValue] = try StudioUIImageData($1.value)
                    }
            }
            return try encoder.encode(resources.store(encoder.encode(images)))
        case "studio.ui.image.faces":
            let source = try await BlockingWork.perform {
                let source = try StudioImageEditorWork.loadSource(
                    document.sourceURL,
                    maxPixelSize: StudioImageEditorModel.previewSize
                ).get()
                return try StudioImageEditorWork.render(
                    document, source: source,
                    size: StudioImageEditorModel.previewSize, geometry: false
                ).get()
            }
            return try encoder.encode(
                await StudioImageEditorWork.faces(in: StudioImageSource(image: source.preview)))
        case "studio.ui.image.export":
            let target: URL
            if let path = object["output"] as? String {
                target = try StudioCommands.localPath(path)
            } else {
                target = StudioImageEditorWork.defaultOutput(
                    for: document.sourceURL,
                    ext: document.outputFormat.fileExtension, destination: model.destination)
            }
            return try encoder.encode(
                work.start { _ in
                    let cancellation = WorkCancellation()
                    try await withTaskCancellationHandler {
                        try await BlockingWork.perform {
                            try ImageEditRenderer.export(
                                document: document, to: target,
                                cancelled: { cancellation.isCancelled })
                        }
                    } onCancel: {
                        cancellation.cancel()
                    }
                    try Task.checkCancellation()
                    model.add([target])
                    model.recordSaved(
                        toolID: "image.edit", title: "Image editor", outputs: [target])
                    return try JSONEncoder().encode(target)
                })
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
