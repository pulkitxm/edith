import EdithCore

public enum StudioResultOperation: String, CaseIterable, Sendable {
    case cancel
    case reveal
    case open

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .cancel:
            descriptor(["cancel"], "Cancel the Studio run that is in progress.", .write)
        case .reveal:
            descriptor(["reveal"], "Reveal Studio result files in Finder.", .interactive)
        case .open:
            descriptor(["open"], "Open a Studio result file.", .interactive)
        }
    }

    public var interfaceExposure: UserOperationExposure {
        switch self {
        case .cancel:
            userInterface("Studio runner", "cancel the run in progress")
        case .reveal:
            userInterface("Studio results", "reveal a result in Finder", ["report.pdf"])
        case .open:
            userInterface("Studio results", "open a result file", ["report.pdf"])
        }
    }

    private func descriptor(_ path: [String], _ summary: String, _ effect: UserOperationEffect)
        -> UserOperationDescriptor
    {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.result.\(rawValue)"), summary: summary,
            cli: ["studio"] + path, effect: effect)
    }
}

private func userInterface(_ surface: String, _ action: String, _ exampleArguments: [String] = [])
    -> UserOperationExposure
{
    .userInterface([
        UserInterfaceActionPlacement(
            surface: surface, action: action, exampleArguments: exampleArguments)
    ])
}
