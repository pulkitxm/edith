import Foundation

extension VideoEditPlan {
    static var documentSchema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object", "additionalProperties": false,
                "required": properties.keys.sorted(), "properties": properties,
            ]
        }
        func number(_ minimum: Double, _ maximum: Double?, _ units: String) -> [String: Any] {
            var result: [String: Any] = [
                "type": "number", "minimum": minimum, "description": units,
            ]
            if let maximum { result["maximum"] = maximum }
            return result
        }
        func string(_ maximum: Int) -> [String: Any] {
            ["type": "string", "minLength": 1, "maxLength": maximum]
        }
        func choice(_ values: [String]) -> [String: Any] {
            ["type": "string", "enum": values]
        }
        let reference = string(1000)
        let alias = string(100)
        let path = string(4096)
        let boolean: [String: Any] = ["type": "boolean"]
        let sourceTime = number(0, nil, "Source seconds, before speed changes and removed ranges.")
        let rulerTime = number(
            0, nil, "Source-time timeline seconds, before speed changes and removed ranges.")
        let outputTime = number(
            0, nil, "Rendered output seconds, after video speed changes and cuts.")
        let gain = number(-60, 12, "Decibels.")
        let fraction = number(0, 1, "Normalized fraction, from left or top.")
        let cropSize = number(0.05, 1, "Normalized source dimension.")
        let stillDuration: [String: Any] = [
            "type": "number", "exclusiveMinimum": 0, "maximum": 604800,
            "description":
                "Still source duration in seconds; output duration also depends on speed and trims.",
        ]
        let pixels: [String: Any] = [
            "type": "integer", "minimum": 2, "maximum": 16384, "multipleOf": 2,
            "description": "Even canvas pixels, independent of clip order.",
        ]
        let rational: [String: Any] = ["type": "integer", "minimum": 1, "maximum": Int32.max]
        let settings = object([
            "width": pixels, "height": pixels,
            "frameRateNumerator": rational, "frameRateDenominator": rational,
            "colorSpace": choice(["rec709", "displayP3"]),
        ]).merging([
            "description":
                "Replace project settings. Numerator divided by denominator must be 1 through 240 frames per output second."
        ]) { _, new in new }
        let keyframe = object([
            "time": sourceTime,
            "scale": [
                "type": "number", "exclusiveMinimum": 0, "maximum": 100,
                "description": "Multiplier after fit/fill.",
            ],
            "positionX": number(-100, 100, "Canvas-width fractions; positive moves right."),
            "positionY": number(-100, 100, "Canvas-height fractions; positive moves down."),
            "rotation": number(-36000, 36000, "Degrees; positive rotates counterclockwise."),
            "interpolation": choice(["linear", "smooth"]),
        ]).merging(["required": ["time"]]) { _, new in new }
        let background = object([
            "framing": choice(["fit", "fill", "fullWidth"]),
            "focalX": fraction, "focalY": fraction,
            "blurRadius": number(
                0, 1000,
                "Gaussian radius in project canvas pixels; default 65. Scales with preview resolution."
            ),
            "sourceCrop": object([
                "x": number(0, 0.95, "Normalized left coordinate of the oriented original."),
                "y": number(0, 0.95, "Normalized top coordinate of the oriented original."),
                "width": cropSize, "height": cropSize,
            ]).merging([
                "description":
                    "Independent background crop. x + width and y + height must not exceed 1. Omission uses the entire original."
            ]) { _, new in new },
        ]).merging([
            "required": [String](),
            "description":
                "Background from the same oriented original, independent of foreground crop and motion. Defaults to fill, centered, radius 65. Color grading applies to both layers. Omit background to disable.",
        ]) { _, new in new }
        let effects = object([
            "gradingMode": choice(["native", "ffmpeg709"]),
            "framing": choice(["fit", "fill", "fullWidth"]), "focalX": fraction, "focalY": fraction,
            "exposure": number(-10, 10, "Exposure stops."),
            "brightness": number(-1, 1, "Brightness adjustment in the selected grading mode."),
            "contrast": number(0, 4, "Core Image contrast multiplier; identity is 1."),
            "saturation": number(0, 4, "Core Image saturation multiplier; identity is 1."),
            "background": background,
            "keyframes": [
                "type": "array", "maxItems": 10000, "items": keyframe,
                "description":
                    "Strictly increasing source times. Interpolation applies to the following interval. An empty array resets animation.",
            ],
        ]).merging([
            "required": [String](),
            "allOf": [
                [
                    "if": [
                        "required": ["gradingMode"],
                        "properties": ["gradingMode": ["const": "ffmpeg709"]],
                    ],
                    "then": ["properties": ["saturation": ["maximum": 3]]],
                ]
            ],
            "description":
                "Replace visual settings; omitted fields reset to fit, centered, neutral native grade, no keyframes and no background. ffmpeg709 grades the composed photo layers before overlays using sRGB-encoded RGB8 and limited-range BT.709 YUV444 EQ; saturation is at most 3. fullWidth scales the selected source crop to canvas width before padding and animation; taller content may extend beyond canvas. Use fit to retain an entire tall image.",
        ]) { _, new in new }
        let operations: [String: [String: Any]] = [
            "addMedia": ["path": path, "name": alias],
            "addStill": ["path": path, "name": alias, "duration": stillDuration],
            "stillDuration": ["clipID": reference, "duration": stillDuration],
            "videoSettings": ["settings": settings],
            "visualEffects": ["clipID": reference, "effects": effects],
            "split": ["clipID": reference, "sourceTime": sourceTime, "rightName": alias],
            "trim": ["clipID": reference, "start": sourceTime, "end": sourceTime],
            "reorder": ["clipIDs": ["type": "array", "items": reference, "uniqueItems": true]],
            "remove": ["clipID": reference],
            "speed": [
                "clipID": reference, "rate": number(0.25, 5, "Source seconds per output second."),
            ],
            "sourceAudio": ["clipID": reference, "gainDb": gain, "muted": boolean],
            "crop": [
                "clipID": reference, "x": number(0, 0.95, "Normalized left coordinate."),
                "y": number(0, 0.95, "Normalized top coordinate."), "width": cropSize,
                "height": cropSize,
            ],
            "resetCrop": ["clipID": reference],
            "text": ["content": string(10000), "start": rulerTime, "end": rulerTime],
            "transition": [
                "clipID": reference, "kind": choice(["none", "fade", "flash"]),
                "duration": number(0.2, 2, "Rendered output seconds."),
            ],
            "addAudio": ["path": path, "start": outputTime, "offset": sourceTime, "name": alias],
            "audioOptions": [
                "trackID": reference, "gainDb": gain, "muted": boolean, "loop": boolean,
            ],
            "removeAudio": ["trackID": reference],
            "rename": ["title": string(1000)],
            "canvas": [
                "aspectRatio": choice(["native", "16:9", "9:16", "1:1", "4:3", "3:4", "21:9"]),
                "padding": number(0, 25, "Percent of canvas dimensions."),
                "backgroundColor": ["type": "string", "pattern": "^#[0-9a-fA-F]{6}$"],
            ],
        ]
        let variants =
            operations.keys.sorted().map { object([$0: object(operations[$0]!)]) }
            + audioEditingSchemas.keys.sorted().map { object([$0: audioEditingSchemas[$0]!]) }
        return object([
            "version": ["type": "integer", "const": 1],
            "operations": ["type": "array", "maxItems": 1000, "items": ["oneOf": variants]],
        ]).merging([
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "Edith video edit plan v1",
        ]) { _, new in new }
    }
}
