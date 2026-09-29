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
        case split(clipID: String, sourceTime: Double, rightName: String)
        case trim(clipID: String, start: Double, end: Double)
        case reorder(clipIDs: [String])
        case remove(clipID: String)
        case speed(clipID: String, rate: Double)
        case sourceAudio(clipID: String, gainDb: Double, muted: Bool)
        case crop(clipID: String, x: Double, y: Double, width: Double, height: Double)
        case resetCrop(clipID: String)
        case text(content: String, start: Double, end: Double)
        case transition(clipID: String, kind: String, duration: Double)
        case addAudio(path: String, start: Double, offset: Double)
        case audioOptions(trackID: String, gainDb: Double, muted: Bool, loop: Bool)
        case removeAudio(trackID: String)
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

    public static func schema() throws -> Data {
        return try JSONSerialization.data(
            withJSONObject: documentSchema, options: [.prettyPrinted, .sortedKeys])
    }

    private static func validateFields(_ value: Any, schema: [String: Any], path: String) throws {
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
            guard Set(object.keys).isSubset(of: Set(fields.keys)),
                required.isSubset(of: Set(object.keys))
            else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "\(path): unknown or missing fields.")
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
