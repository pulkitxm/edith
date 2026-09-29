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
        for (index, operation) in operations.enumerated() {
            guard operation.count == 1, let name = operation.keys.first,
                let fields = operation[name] as? [String: Any],
                let definition = definitions[name], Set(fields.keys) == Set(definition.keys)
            else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "Operation \(index) has unknown or missing fields.")
            }
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static let definitions: [String: [String: String]] = [
        "addMedia": ["path": "string", "name": "string"],
        "split": ["clipID": "string", "sourceTime": "number", "rightName": "string"],
        "trim": ["clipID": "string", "start": "number", "end": "number"],
        "reorder": ["clipIDs": "array"],
        "remove": ["clipID": "string"],
        "speed": ["clipID": "string", "rate": "number"],
        "sourceAudio": ["clipID": "string", "gainDb": "number", "muted": "boolean"],
        "crop": [
            "clipID": "string", "x": "number", "y": "number", "width": "number", "height": "number",
        ],
        "resetCrop": ["clipID": "string"],
        "text": ["content": "string", "start": "number", "end": "number"],
        "transition": ["clipID": "string", "kind": "string", "duration": "number"],
        "addAudio": ["path": "string", "start": "number", "offset": "number"],
        "audioOptions": [
            "trackID": "string", "gainDb": "number", "muted": "boolean", "loop": "boolean",
        ],
        "removeAudio": ["trackID": "string"],
        "rename": ["title": "string"],
        "canvas": ["aspectRatio": "string", "padding": "number", "backgroundColor": "string"],
    ]

    public static func schema() throws -> Data {
        let variants: [[String: Any]] = definitions.keys.sorted().map { name in
            let fields = definitions[name]!
            let properties = Dictionary(
                uniqueKeysWithValues: fields.map { field, type in
                    (
                        field,
                        (["type": type] as [String: Any]).merging(constraints(field)) {
                            _, constraint in constraint
                        }
                    )
                })
            return [
                "type": "object", "additionalProperties": false, "required": [name],
                "properties": [
                    name: [
                        "type": "object", "additionalProperties": false,
                        "required": fields.keys.sorted(), "properties": properties,
                    ]
                ],
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "title": "Edith video edit plan v1", "type": "object",
                "additionalProperties": false, "required": ["version", "operations"],
                "properties": [
                    "version": ["const": 1],
                    "operations": [
                        "type": "array", "maxItems": 1000, "items": ["oneOf": variants],
                    ],
                ],
            ], options: [.prettyPrinted, .sortedKeys])
    }

    private static func constraints(_ field: String) -> [String: Any] {
        switch field {
        case "clipIDs": ["items": ["type": "string"], "uniqueItems": true]
        case "rate": ["minimum": 0.25, "maximum": 5]
        case "gainDb": ["minimum": -60, "maximum": 12]
        case "padding": ["minimum": 0, "maximum": 25]
        case "duration": ["minimum": 0.2, "maximum": 2]
        case "start", "offset", "sourceTime", "end": ["minimum": 0]
        case "x", "y": ["minimum": 0, "maximum": 0.95]
        case "width", "height": ["minimum": 0.05, "maximum": 1]
        case "name", "rightName": ["minLength": 1, "maxLength": 100]
        case "title": ["minLength": 1, "maxLength": 1000]
        case "content": ["minLength": 1, "maxLength": 10000]
        case "path", "clipID", "trackID": ["minLength": 1]
        case "kind": ["enum": ["none", "fade", "flash"]]
        case "aspectRatio": ["enum": ["native", "16:9", "9:16", "1:1", "4:3", "3:4", "21:9"]]
        case "backgroundColor": ["pattern": "^#[0-9a-fA-F]{6}$"]
        default: [:]
        }
    }
}
