import EdithCore

public enum StudioDeliveryOperation: String, CaseIterable, Sendable {
    case renderAudio = "render-audio"

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit.\(rawValue)"),
            summary: "Encode the native audio mix as WAV, AIFF or M4A with a measured report.",
            cli: ["studio", "edit", rawValue], effect: .write)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(reason: "Headless delivery uses the native video editor audio mix.")
    }
}
