import EdithCore

public enum StudioEditMarkerOperation: String, CaseIterable, Sendable {
    case analyze, list, add, update, remove, `import`, export, snap

    public var descriptor: UserOperationDescriptor {
        let components = self == .analyze ? ["audio", "analyze"] : ["markers", rawValue]
        return UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit." + components.joined(separator: ".")),
            summary: summary, cli: ["studio", "edit"] + components, effect: effect)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(
            reason: "Typed headless audio analysis and output-frame marker operations.")
    }

    private var effect: UserOperationEffect {
        switch self {
        case .analyze, .list, .snap: .read
        case .add, .update, .remove, .import, .export: .write
        }
    }

    private var summary: String {
        switch self {
        case .analyze:
            "Measure bounded source-sample waveforms and transients with explicit output mapping; five-minute MCP limit."
        case .list: "List output-frame markers with their saved rational FPS."
        case .add: "Transactionally add a marker at an output frame with explicit or project FPS."
        case .update: "Transactionally update marker frame, FPS or label by ID."
        case .remove: "Transactionally remove a marker by ID."
        case .import: "Validate and transactionally import a version 1 marker document."
        case .export: "Export marker JSON without overwriting project dependencies or sidecars."
        case .snap: "Find a marker within an inclusive output-frame threshold without writing."
        }
    }
}
