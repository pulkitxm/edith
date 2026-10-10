import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor final class UsageExportDelivery {
    typealias ChooseURL = @MainActor (String) async throws -> URL?
    typealias Copy = @MainActor (Data) throws -> Void
    private struct Upload {
        let byteCount: Int
        let sha256: String
        let filename: String
        let save: Bool
        let expires: Date
        var data = Data()
    }
    private let chooseURL: ChooseURL
    private let copy: Copy
    private var uploads: [UUID: Upload] = [:]
    private var deliveries: [UUID: Task<String, Error>] = [:]
    private var stopped = false

    init(
        chooseURL: @escaping ChooseURL = {
            await ExportDelivery.chooseSaveURL(suggestedName: $0, in: nil)
        }, copy: @escaping Copy = { try ExportDelivery.copyPNG($0) }
    ) {
        self.chooseURL = chooseURL
        self.copy = copy
    }

    func stop() {
        stopped = true
        uploads = [:]
        for task in deliveries.values { task.cancel() }
    }

    func stopAndWait() async {
        stop()
        let pending = Array(deliveries.values)
        for task in pending { _ = try? await task.value }
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, payload.count <= 131_072,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        uploads = uploads.filter { $0.value.expires > Date() }
        let encoder = JSONEncoder()
        if command == "usage.ui.export.begin" {
            guard Set(object.keys) == ["byteCount", "sha256", "filename", "save"],
                let count = object["byteCount"] as? Int, (1...16_777_216).contains(count),
                let hash = object["sha256"] as? String, hash.count == 64,
                hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                let filename = object["filename"] as? String,
                UsageShareCard.allCases.contains(where: { $0.filenameStem + ".png" == filename }),
                let save = object["save"] as? Bool, uploads.count + deliveries.count < 4
            else { throw ExtensionPeerError.invalidRequest }
            let id = UUID()
            uploads[id] = Upload(
                byteCount: count, sha256: hash, filename: filename, save: save,
                expires: Date().addingTimeInterval(60))
            return try encoder.encode(id)
        }
        guard let text = object["id"] as? String, let id = UUID(uuidString: text) else {
            throw ExtensionPeerError.invalidRequest
        }
        if command == "usage.ui.export.cancel" {
            guard Set(object.keys) == ["id"] else { throw ExtensionPeerError.invalidRequest }
            uploads[id] = nil
            deliveries[id]?.cancel()
            return Data("{}".utf8)
        }
        if command == "usage.ui.export.chunk" {
            guard Set(object.keys) == ["id", "offset", "data"],
                let offset = object["offset"] as? Int,
                let text = object["data"] as? String, let data = Data(base64Encoded: text),
                (1...65_536).contains(data.count), var upload = uploads[id],
                offset == upload.data.count, offset + data.count <= upload.byteCount
            else { throw ExtensionPeerError.invalidRequest }
            upload.data.append(data)
            uploads[id] = upload
            return Data("{}".utf8)
        }
        guard command == "usage.ui.export.deliver", Set(object.keys) == ["id"],
            let upload = uploads.removeValue(forKey: id),
            upload.data.count == upload.byteCount,
            UsageMachinesPeer.hash(upload.data) == upload.sha256,
            let source = CGImageSourceCreateWithData(upload.data as CFData, nil),
            CGImageSourceGetType(source) as String? == UTType.png.identifier,
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            properties[kCGImagePropertyPixelWidth] as? Int == 2_400,
            properties[kCGImagePropertyPixelHeight] as? Int == 1_600,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == 2_400, image.height == 1_600
        else { throw ExtensionPeerError.invalidRequest }
        let operation = Task { [chooseURL, copy] in
            try Task.checkCancellation()
            if upload.save {
                guard let url = try await chooseURL(upload.filename) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                try ExportDelivery.write(upload.data, to: url)
                return "Saved \(url.lastPathComponent)"
            }
            try copy(upload.data)
            return "Copied image"
        }
        deliveries[id] = operation
        defer { deliveries[id] = nil }
        let message = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        return try encoder.encode(message)
    }
}
