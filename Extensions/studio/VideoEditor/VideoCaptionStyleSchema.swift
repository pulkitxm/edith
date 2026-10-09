import Foundation

extension VideoCaptionStyle {
    static func object(_ properties: [String: Any], optional: Set<String> = []) -> [String: Any] {
        [
            "type": "object", "additionalProperties": false, "properties": properties,
            "required": properties.keys.filter { !optional.contains($0) }.sorted(),
        ]
    }

    static var schema: [String: Any] {
        func number(_ low: Double, _ high: Double) -> [String: Any] {
            ["type": "number", "minimum": low, "maximum": high]
        }
        func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        let name: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 200]
        let fraction = number(0, 1)
        let color = object([
            "red": fraction, "green": fraction, "blue": fraction, "alpha": fraction,
        ])
        return object(
            [
                "canvasWidth": number(2, 16384), "canvasHeight": number(2, 16384),
                "fontFamily": name, "fontStyle": name, "fontSize": number(1, 2048),
                "lineAdvance": number(1, 4096), "alignment": choice(["left", "center", "right"]),
                "anchor": choice(["top", "center", "bottom"]),
                "metrics": choice(["typographic", "fontBounds"]),
                "x": number(0, 16384), "y": number(0, 16384), "width": number(1, 16384),
                "fill": color,
                "outline": object(["width": number(0, 128), "color": color]),
                "shadow": object(
                    [
                        "x": number(-2048, 2048), "y": number(-2048, 2048), "blur": number(0, 256),
                        "strokeWidth": number(0, 128), "color": color, "strokeColor": color,
                    ], optional: ["strokeColor"]),
                "gradient": object([
                    "startY": number(0, 16384), "endY": number(0, 16384),
                    "stops": [
                        "type": "array", "minItems": 2, "maxItems": 16,
                        "items": object(["location": fraction, "color": color]),
                    ],
                ]),
            ], optional: ["outline", "shadow", "gradient", "metrics"]
        ).merging([
            "description":
                "All dimensions use reference-canvas pixels. X anchors left/center/right by alignment; Y anchors the top/center/bottom of the text block. Y and shadow Y increase downwards. Gradient locations are fractions between startY and endY, extended flat outside that interval."
        ]) { _, new in new }
    }
}

extension VideoEditPlan {
    static var captionEditingSchemas: [String: [String: Any]] {
        let content: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 10000]
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 200]
        let time: [String: Any] = [
            "type": "number", "minimum": 0,
            "description": "Source-time timeline seconds, before speed changes and removed ranges.",
        ]
        let rational: [String: Any] = ["type": "integer", "minimum": 1, "maximum": Int32.max]
        let position = VideoCaptionStyle.object(
            [
                "frame": ["type": "integer", "minimum": 0, "maximum": VideoMarker.maximumFrame],
                "frameRate": VideoCaptionStyle.object([
                    "numerator": rational, "denominator": rational,
                ]),
                "markerID": id,
            ], optional: ["markerID"])
        return [
            "text": VideoCaptionStyle.object(
                [
                    "content": content, "start": time, "end": time,
                    "style": VideoCaptionStyle.schema,
                ], optional: ["style"]),
            "outputCaption": VideoCaptionStyle.object(
                [
                    "id": id, "content": content,
                    "anchor": VideoCaptionStyle.object(["start": position, "end": position]),
                    "style": VideoCaptionStyle.schema,
                ], optional: ["id", "style"]),
            "captionStyle": VideoCaptionStyle.object(["id": id, "style": VideoCaptionStyle.schema]),
        ]
    }
}
