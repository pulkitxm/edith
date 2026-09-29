import EdithCore

public enum StudioEditOperation: String, CaseIterable, Sendable {
    case schema, create, show, apply, validate, render, frame

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit.\(rawValue)"), summary: summary,
            cli: ["studio", "edit", rawValue], effect: effect)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(
            reason: "Headless project-file operations share the native video editor pipeline.")
    }

    private var effect: UserOperationEffect {
        switch self {
        case .schema, .show, .validate: .read
        case .create, .apply, .render, .frame: .write
        }
    }

    private var summary: String {
        switch self {
        case .schema: "Print the typed video edit-plan JSON Schema."
        case .create: "Create a native video project; existing files require --overwrite."
        case .show: "Inspect native project JSON and persisted clip and audio IDs."
        case .apply: "Atomically apply a typed edit plan; --dry-run validates without writing."
        case .validate: "Validate a project's structure, local media and native composition."
        case .render: "Render a native project to MP4, with a six-hour execution limit."
        case .frame: "Extract a composited PNG frame at a rendered output time."
        }
    }
}
