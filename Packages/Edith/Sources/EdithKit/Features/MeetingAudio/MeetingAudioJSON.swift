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
            "voice": .string(preset.rawValue), "pitch": .double(Double(pitch)),
            "reverb": .double(Double(reverb)), "delay": .double(Double(delay)),
            "recording": .optional(status?.recordingName), "error": .optional(status?.failure),
            "playing": .array((status?.playing ?? []).map { .string($0) }),
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
