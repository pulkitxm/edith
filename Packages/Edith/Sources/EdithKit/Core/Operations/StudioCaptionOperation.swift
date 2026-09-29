import EdithCore

public enum StudioCaptionOperation: String, CaseIterable, Sendable {
    case list, add, update, remove

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit.captions.\(rawValue)"), summary: summary,
            cli: ["studio", "edit", "captions", rawValue], effect: self == .list ? .read : .write)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(
            reason: "Headless captions share the native editor's output clock and renderer.")
    }

    private var summary: String {
        switch self {
        case .list: "List captions with stable IDs and explicit source/output clocks."
        case .add: "Add a caption using output frames or snapshotted marker positions."
        case .update: "Update a caption by ID without changing its output anchor implicitly."
        case .remove: "Remove an existing caption by stable ID."
        }
    }
}
