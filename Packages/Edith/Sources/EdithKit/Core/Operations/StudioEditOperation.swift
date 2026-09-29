import EdithCore

public enum StudioEditOperation: String, CaseIterable, Sendable {
    case schema, create, show, apply, validate, render, frame
    case list, clone
    case contactSheet = "contact-sheet"

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
        case .schema, .show, .validate, .list: .read
        case .create, .apply, .render, .frame, .clone, .contactSheet: .write
        }
    }

    private var summary: String {
        switch self {
        case .schema: "Print the typed video edit-plan JSON Schema."
        case .create: "Create a native video project; existing files require --overwrite."
        case .show: "Inspect native project JSON and persisted clip and audio IDs."
        case .apply: "Atomically apply a typed edit plan; --dry-run validates without writing."
        case .validate: "Validate a project's structure, local media and native composition."
        case .render:
            "Encode native video with explicit codec settings and a measured delivery report."
        case .frame: "Extract a composited PNG frame at a rendered output time."
        case .list: "List project identities and titles in a local directory."
        case .clone: "Copy a native edit with a fresh project identity."
        case .contactSheet: "Render a labeled contact sheet of up to 64 output frames."
        }
    }
}
