import EdithCore
import Foundation

public enum ScratchpadOperation: String, CaseIterable, Sendable {
    case list
    case show
    case create
    case update
    case rename
    case duplicate
    case remove
    case clear
    case copyAll
    case export
    case open
    case remember

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "scratchpad.\(rawValue)"), summary: summary,
            cli: ["scratchpad", command], effect: effect,
            requiresPreview: self == .remove || self == .clear)
    }

    public var interfaceExposure: UserOperationExposure {
        switch self {
        case .list, .show:
            .commandLineOnly(reason: "The panel presents the same pads directly.")
        case .create:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "New pad")
            ])
        case .update:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "Edit text")
            ])
        case .rename:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "Rename pad")
            ])
        case .duplicate:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "Duplicate pad")
            ])
        case .remove:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "Delete pad")
            ])
        case .clear:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "Clear pad")
            ])
        case .copyAll:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "Copy all")
            ])
        case .export:
            .userInterface([
                UserInterfaceActionPlacement(surface: "Scratchpad panel", action: "Export pad")
            ])
        case .open:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Scratchpad settings", action: "Open Scratchpad")
            ])
        case .remember:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Scratchpad panel", action: "Remember in Companion")
            ])
        }
    }

    private var command: String {
        switch self {
        case .list: "ls"
        case .update: "set"
        case .remove: "rm"
        case .copyAll: "copy-all"
        default: rawValue
        }
    }

    private var summary: String {
        switch self {
        case .list: "List scratchpads."
        case .show: "Read one scratchpad."
        case .create: "Create a scratchpad."
        case .update: "Replace a scratchpad's text."
        case .rename: "Rename a scratchpad."
        case .duplicate: "Duplicate a scratchpad."
        case .remove: "Remove a scratchpad."
        case .clear: "Clear a scratchpad."
        case .copyAll: "Copy all text from a scratchpad."
        case .export: "Export a scratchpad to a text file."
        case .open: "Open the Scratchpad panel."
        case .remember: "Promote a scratchpad into Companion memory."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .list, .show: .read
        case .create, .update, .rename, .duplicate, .copyAll, .export, .open, .remember: .write
        case .remove, .clear: .destructive
        }
    }
}
