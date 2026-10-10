import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

public extension MeetingAudioDevice {
    var jsonValue: JSONValue {
        .object([
            "id": .string(id), "name": .string(name), "inputChannels": .int(inputChannels),
            "outputChannels": .int(outputChannels), "virtual": .bool(virtual),
        ])
    }
}

public extension MeetingAudioState {
    func jsonValue(status: MeetingAudioStatus?) -> JSONValue {
        .object([
            "enabled": .bool(enabled), "running": .bool(status?.running ?? false),
            "input": .optional(inputID), "output": .optional(outputID),
            "inputName": .optional(status?.inputName), "outputName": .optional(status?.outputName),
            "muted": .bool(muted), "micGain": .double(Double(micGain)),
            "clipsGain": .double(Double(clipsGain)), "sourceGain": .double(Double(sourceGain)),
            "voiceModel": .optional(voiceModelID?.uuidString),
            "voiceTranspose": .double(Double(voiceTranspose)),
            "voiceModels": .array(
                voiceModels.map {
                    .object([
                        "id": .string($0.id.uuidString), "name": .string($0.name),
                        "encoder": .string($0.encoderPath), "model": .string($0.voicePath),
                    ])
                }),
            "voice": .string(preset.rawValue), "pitch": .double(Double(pitch)),
            "reverb": .double(Double(reverb)), "delay": .double(Double(delay)),
            "recording": .optional(status?.recordingName), "error": .optional(status?.failure),
            "sourceError": .optional(status?.sourceFailure),
            "playing": .array((status?.playing ?? []).map { .string($0) }),
            "sounds": .array(
                MeetingSound.allCases.map {
                    .object(["id": .string($0.identifier), "name": .string($0.name)])
                }),
            "clips": .array(
                clips.map {
                    .object([
                        "id": .string($0.id.uuidString), "name": .string($0.name),
                        "path": .string($0.path), "speech": .bool($0.speech),
                        "start": .double($0.start), "end": $0.end.map { .double($0) } ?? .null,
                        "gain": .double(Double($0.gain)),
                    ])
                }),
        ])
    }
}
