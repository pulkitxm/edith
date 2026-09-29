import EdithCore

public enum StudioPublicationOperation: String, CaseIterable, Sendable {
    case create, show, reorder

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit.publications.\(rawValue)"),
            summary: summary, cli: ["studio", "edit", "publications", rawValue],
            effect: self == .show ? .read : .write)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(reason: "External upload-order manifests preserve native project files.")
    }

    private var summary: String {
        switch self {
        case .create:
            "Create a version 1 publication manifest from --input; --dry-run previews and --overwrite replaces."
        case .show: "Validate publication identities and local files, then print manifest JSON."
        case .reorder:
            "Reorder publication references by stable IDs from --input; requires --overwrite and supports --dry-run."
        }
    }
}
