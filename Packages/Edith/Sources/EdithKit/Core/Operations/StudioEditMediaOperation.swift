import EdithCore

public enum StudioEditMediaOperation: String, CaseIterable, Sendable {
    case identity, probe, duplicates, chronology, index, provenance, usage
    case package, open, relink

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.edit.media.\(rawValue)"),
            summary: summary, cli: ["studio", "edit", "media", rawValue], effect: effect)
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(reason: "Headless local media identity and project-file operations.")
    }

    private var effect: UserOperationEffect {
        switch self {
        case .identity, .probe, .duplicates, .chronology, .usage: .read
        case .index, .provenance, .package, .open, .relink: .write
        }
    }

    private var summary: String {
        switch self {
        case .identity: "Stream a SHA-256 identity for one original media file."
        case .probe: "Probe actual media formats and capture-time certainty."
        case .duplicates: "Find exact copies across local media paths."
        case .chronology: "Sort media by known UTC capture time with deterministic ties."
        case .usage: "Audit every clip occurrence for exact or declared-family original reuse."
        case .package: "Atomically publish a portable copy of every original media dependency."
        case .open: "Verify and rebase a moved media package without opening a window."
        case .relink:
            "Relink a media reference with identity verification and revision-safe publication."
        case .index: "Record verified media identities with revision-checked project publication."
        case .provenance: "Declare an explicit original-source family for alternate exports."
        }
    }
}
