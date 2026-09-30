import EdithCore

public enum StudioEditAudioOperation: String, CaseIterable, Sendable {
    case health, measure, master

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit.audio.\(rawValue)"),
            summary: summary, cli: ["studio", "edit", "audio", rawValue],
            effect: self == .master ? .write : .read)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(
            reason:
                "Typed local soundtrack mastering and measurement with explicit FFmpeg preflight.")
    }

    private var summary: String {
        switch self {
        case .health:
            "Report FFmpeg loudnorm availability, executable and version without installing anything."
        case .measure:
            "Measure integrated LUFS, LRA and true peak; silence has absent integrated/peak values."
        case .master:
            "Create a new immutable 48 kHz stereo PCM soundtrack bundle with verified two-pass loudness, provenance and an editable project copy."
        }
    }
}
