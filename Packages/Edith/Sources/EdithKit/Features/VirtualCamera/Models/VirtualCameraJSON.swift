import EdithCameraSupport
import Foundation

public extension VirtualCameraSource {
    var jsonValue: JSONValue {
        .object(["id": .string(id), "name": .string(name), "kind": .string(kind.rawValue)])
    }
}

public extension VirtualCameraScene {
    func jsonValue(index: Int, active: Bool) -> JSONValue {
        let framing = composition.framing
        return .object([
            "id": .string(id.uuidString),
            "number": .int(index + 1),
            "name": .string(name),
            "active": .bool(active),
            "zoom": .double(framing.zoom),
            "look": .string(composition.look.preset.rawValue),
            "background": .string(composition.background.mode.rawValue),
            "camera": .optional(sourceID),
        ])
    }
}

public extension VirtualCameraSnapshot {
    var jsonValue: JSONValue {
        let framing = state.composition.framing
        return .object([
            "enabled": .bool(enabled),
            "helperRunning": .bool(helperRunning),
            "extensionInstalled": .bool(extensionInstalled),
            "obsAvailable": .bool(obsAvailable),
            "route": .optional(route?.rawValue),
            "extensionBuild": .optional(extensionBuild),
            "live": .bool(live),
            "headline": .string(headline),
            "apps": .array(
                clients.map { .object(["id": .string($0.id), "name": .string($0.name)]) }),
            "framesPerSecond": .double(framesPerSecond),
            "camera": source?.jsonValue ?? .null,
            "cameraResolution": sourceWidth > 0
                ? .string("\(sourceWidth)x\(sourceHeight)") : .null,
            "output": .object([
                "width": .int(format.width), "height": .int(format.height),
                "frameRate": .int(format.frameRate),
            ]),
            "cameraAccess": .string(cameraAccess),
            "privacy": .string(state.privacy.rawValue),
            "privacyMessage": .string(state.privacyMessage),
            "scene": .optional(state.activeScene?.name),
            "sceneModified": .bool(state.activeSceneIsModified),
            "framing": .object([
                "zoom": .double(framing.zoom),
                "x": .double(framing.centerX),
                "y": .double(framing.centerY),
                "tilt": .double(framing.tilt),
                "turns": .int(framing.quarterTurns),
                "flipHorizontal": .bool(framing.flipHorizontal),
                "flipVertical": .bool(framing.flipVertical),
                "auto": .string(framing.autoFrame.rawValue),
            ]),
            "look": .string(state.composition.look.preset.rawValue),
            "background": .string(state.composition.background.mode.rawValue),
            "message": .optional(message),
        ])
    }

    var scenesJSON: JSONValue {
        .array(
            state.scenes.enumerated().map { index, scene in
                scene.jsonValue(index: index, active: scene.id == state.activeSceneID)
            })
    }

    var summaryLines: [String] {
        let framing = state.composition.framing
        var lines = [
            "state: \(headline)",
            "camera: \(source?.name ?? "none")"
                + (sourceWidth > 0 ? " (\(sourceWidth)x\(sourceHeight))" : ""),
            "output: \(format.label)",
            "zoom: \(String(format: "%.2f", framing.zoom))x"
                + (framing.autoFrame == .off ? "" : ", auto framing \(framing.autoFrame.rawValue)"),
            "look: \(state.composition.look.preset.title)",
            "background: \(state.composition.background.mode.title)",
            "privacy: \(state.privacy.title)",
            "scene: \(state.activeScene?.name ?? "none")"
                + (state.activeSceneIsModified ? " (changed)" : ""),
            "camera access: \(cameraAccess)",
            "extension: \(extensionInstalled ? "installed" : "not installed")",
            "sending to: \(route?.cameraName ?? "nothing yet")",
        ]
        if !clients.isEmpty {
            lines.append("apps: \(clients.map(\.name).joined(separator: ", "))")
        }
        return lines
    }
}
