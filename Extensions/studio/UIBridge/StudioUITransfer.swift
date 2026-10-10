import EdithExtensionSupport
import Foundation

extension StudioUIFacade {
    func object<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    func download<Value: Decodable>(_ handle: StudioUIResource, as: Value.Type = Value.self)
        async throws -> Value
    {
        guard (0...StudioUIResources.maximumBytes).contains(handle.length) else {
            throw ExtensionEngineError.rejected
        }
        do {
            var data = Data()
            let value = try object(handle)
            while data.count < handle.length {
                try Task.checkCancellation()
                let chunk: Data = try await read(
                    "studio.ui.blob.read",
                    object: ["handle": value, "offset": data.count])
                guard !chunk.isEmpty, chunk.count <= StudioUIResources.chunkBytes,
                    chunk.count <= handle.length - data.count
                else { throw ExtensionEngineError.rejected }
                data.append(chunk)
            }
            let _: [String: String] = try await read(
                "studio.ui.blob.end", object: ["handle": value])
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            let value = try? object(handle)
            if let value {
                Task {
                    let _: [String: String]? = try? await self.read(
                        "studio.ui.blob.end", object: ["handle": value])
                }
            }
            throw error
        }
    }

    func upload<Value: Encodable>(_ value: Value) async throws -> StudioUIResource {
        let data = try JSONEncoder().encode(value)
        guard data.count <= StudioUIResources.maximumBytes else {
            throw ExtensionEngineError.rejected
        }
        let handle: StudioUIResource = try await read(
            "studio.ui.blob.create", object: ["length": data.count])
        do {
            let value = try object(handle)
            for offset in stride(from: 0, to: data.count, by: StudioUIResources.chunkBytes) {
                try Task.checkCancellation()
                let bytes = data.subdata(
                    in: offset..<min(offset + StudioUIResources.chunkBytes, data.count))
                let _: [String: String] = try await read(
                    "studio.ui.blob.write",
                    object: [
                        "handle": value, "offset": offset, "data": bytes.base64EncodedString(),
                    ])
            }
            return handle
        } catch {
            if let value = try? object(handle) {
                Task {
                    let _: [String: String]? = try? await self.read(
                        "studio.ui.blob.end", object: ["handle": value])
                }
            }
            throw error
        }
    }
}
