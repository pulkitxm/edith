import Foundation

public struct VideoEditPlan: Codable, Sendable {
    public let version: Int
    public let operations: [Operation]

    public init(version: Int = 1, operations: [Operation]) {
        self.version = version
        self.operations = operations
    }

    public enum Operation: Codable, Sendable {
        case addMedia(path: String, name: String)
        case addStill(path: String, name: String, duration: Double)
        case stillDuration(clipID: String, duration: Double)
        case videoSettings(settings: VideoSettings)
        case visualEffects(clipID: String, effects: VideoVisualEffects)
        case frameSampling(clipID: String, mode: VideoFrameSampling)
        case split(clipID: String, sourceTime: Double, rightName: String)
        case trim(clipID: String, start: Double, end: Double)
        case reorder(clipIDs: [String])
        case remove(clipID: String)
        case speed(clipID: String, rate: Double)
        case sourceAudio(clipID: String, gainDb: Double, muted: Bool)
        case crop(clipID: String, x: Double, y: Double, width: Double, height: Double)
        case resetCrop(clipID: String)
        case text(content: String, start: Double, end: Double, style: VideoCaptionStyle? = nil)
        case outputCaption(
            id: String? = nil, content: String, anchor: VideoCaptionAnchor,
            style: VideoCaptionStyle? = nil)
        case captionStyle(id: String, style: VideoCaptionStyle)
        case transition(clipID: String, kind: String, duration: Double)
        case addAudio(path: String, start: Double, offset: Double, name: String)
        case audioOptions(trackID: String, gainDb: Double, muted: Bool, loop: Bool)
        case removeAudio(trackID: String)
        case detachAudio(clipID: String, name: String)
        case moveAudio(trackID: String, start: Double)
        case splitAudio(trackID: String, time: Double, rightName: String)
        case trimAudio(trackID: String, start: Double, end: Double)
        case audioFades(trackID: String, fadeIn: Double?, fadeOut: Double?)
        case rename(title: String)
        case canvas(aspectRatio: String, padding: Double, backgroundColor: String)
    }

    public static func decode(_ data: Data) throws -> Self {
        do {
            let plan = try decodeChecked(data)
            guard plan.version == 1 else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "Only edit-plan version 1 is supported.")
            }
            return plan
        } catch let error as DecodingError {
            let context: DecodingError.Context
            switch error {
            case .typeMismatch(_, let detail), .valueNotFound(_, let detail),
                .keyNotFound(_, let detail), .dataCorrupted(let detail):
                context = detail
            @unknown default:
                throw VideoEditorService.Failure("invalid_plan", "Could not decode edit plan.")
            }
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw VideoEditorService.Failure("invalid_plan", "\(path): \(context.debugDescription)")
        } catch {
            throw VideoEditorService.Failure("invalid_plan", error.localizedDescription)
        }
    }

    private static func decodeChecked(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else {
            throw VideoEditorService.Failure("invalid_plan", "Edit plans must be at most 4 MiB.")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys) == ["version", "operations"],
            let operations = root["operations"] as? [[String: Any]], operations.count <= 1000
        else {
            throw VideoEditorService.Failure(
                "invalid_plan", "Expected version and up to 1000 operations.")
        }
        try validateFields(root, schema: documentSchema, path: "plan")
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public static func schema(operation: String? = nil) throws -> Data {
        var selected = documentSchema
        if let operation {
            let properties = selected["properties"] as? [String: Any]
            let operations = properties?["operations"] as? [String: Any]
            let items = operations?["items"] as? [String: Any]
            let variants = items?["oneOf"] as? [[String: Any]] ?? []
            guard
                let variant = variants.first(where: {
                    ($0["properties"] as? [String: Any])?[operation] != nil
                })
            else {
                throw VideoEditorService.Failure(
                    "invalid_operation",
                    "Unknown plan operation '\(operation)'. Use schema to list operations.")
            }
            selected = variant
            selected["$schema"] = "https://json-schema.org/draft/2020-12/schema"
            selected["title"] = "Edith edit-plan operation: \(operation)"
        }
        return try JSONSerialization.data(
            withJSONObject: selected, options: [.prettyPrinted, .sortedKeys])
    }

    static func validateFields(_ value: Any, schema: [String: Any], path: String) throws {
        guard !(value is NSNull) else {
            throw VideoEditorService.Failure(
                "invalid_plan", "\(path): null is not a valid field value.")
        }
        if let variants = schema["oneOf"] as? [[String: Any]] {
            guard let object = value as? [String: Any], object.count == 1,
                let name = object.keys.first,
                let variant = variants.first(where: {
                    ($0["properties"] as? [String: Any])?[name] != nil
                })
            else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "\(path): expected one known operation.")
            }
            try validateFields(value, schema: variant, path: path)
        } else if let fields = schema["properties"] as? [String: [String: Any]],
            let object = value as? [String: Any]
        {
            let required = Set(schema["required"] as? [String] ?? [])
            if let alternatives = schema["anyOf"] as? [[String: [String]]],
                !alternatives.contains(where: {
                    Set($0["required"] ?? []).isSubset(of: Set(object.keys))
                })
            {
                throw VideoEditorService.Failure(
                    "invalid_plan", "\(path): specify at least one fade duration.")
            }
            guard Set(object.keys).isSubset(of: Set(fields.keys)),
                required.isSubset(of: Set(object.keys))
            else {
                let unknown = Set(object.keys).subtracting(fields.keys).sorted()
                let missing = required.subtracting(object.keys).sorted()
                let details = [
                    unknown.isEmpty ? nil : "unknown fields: \(unknown.joined(separator: ", "))",
                    missing.isEmpty ? nil : "missing fields: \(missing.joined(separator: ", "))",
                ].compactMap { $0 }.joined(separator: "; ")
                throw VideoEditorService.Failure("invalid_plan", "\(path): \(details).")
            }
            for (name, child) in object {
                try validateFields(child, schema: fields[name]!, path: "\(path).\(name)")
            }
        } else if let items = schema["items"] as? [String: Any], let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                try validateFields(child, schema: items, path: "\(path)[\(index)]")
            }
        }
    }
}
