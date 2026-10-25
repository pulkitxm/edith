import Foundation

extension VideoEditPlan {
    static var audioEditingSchemas: [String: [String: Any]] {
        let reference: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 1000]
        let alias: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 100]
        let time: [String: Any] = [
            "type": "number", "minimum": 0, "maximum": 604800,
            "description": "Rendered output seconds, independent of the source-time ruler.",
        ]
        func operation(_ properties: [String: Any], required: [String]? = nil) -> [String: Any] {
            [
                "type": "object", "additionalProperties": false,
                "properties": properties, "required": required ?? properties.keys.sorted(),
            ]
        }
        var fades = operation(
            ["trackID": reference, "fadeIn": time, "fadeOut": time], required: ["trackID"])
        fades["anyOf"] = [["required": ["fadeIn"]], ["required": ["fadeOut"]]]
        return [
            "detachAudio": operation(["clipID": reference, "name": alias]),
            "moveAudio": operation(["trackID": reference, "start": time]),
            "splitAudio": operation(["trackID": reference, "time": time, "rightName": alias]),
            "trimAudio": operation(["trackID": reference, "start": time, "end": time]),
            "audioFades": fades,
        ]
    }
}
