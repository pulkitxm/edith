import EdithCore

public enum StudioEditOperation: String, CaseIterable, Sendable {
    case schema, create, show, apply, validate, render, frame
    case list, clone
    case register, unregister, library, open
    case contactSheet = "contact-sheet"
    case reviewReport = "review-report"

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit.\(rawValue)"), summary: summary,
            cli: ["studio", "edit", rawValue], effect: effect)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(
            reason:
                "Project-file operations and native editor handoff are available through the command line."
        )
    }

    private var effect: UserOperationEffect {
        switch self {
        case .schema, .show, .validate, .list, .library: .read
        case .register, .unregister: .write
        case .open: .interactive
        case .create, .apply, .render, .frame, .clone, .contactSheet, .reviewReport: .write
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
        case .register: "Register a canonical project reference without copying or modifying it."
        case .unregister: "Remove a library reference without deleting its project or media."
        case .library: "List native and registered projects, including stale reference errors."
        case .open:
            "Open an exact project revision in the running native editor and await its mounted acknowledgment."
        case .contactSheet:
            "Render up to 64 labeled output frames with optional saved-marker and explicitly mapped source-waveform strips."
        case .reviewReport:
            "Report native timing, expected counts, missing assets and optional sampled border geometry."
        }
    }
}
