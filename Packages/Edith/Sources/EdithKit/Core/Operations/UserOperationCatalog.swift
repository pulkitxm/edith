import EdithCore

public enum UserOperationCatalog {
    public static let registrations =
        MachineControlOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ExtensionMutationOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + CalendarEventOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ShelfItemOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + DownloadOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MusicLibraryOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MusicTransportOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MusicCurrentOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + PresenterRuntimeOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ConfigurationOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + PermissionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ColorPickerOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ColorSwatchOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + CompanionSettingsOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ClipboardOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + AttentionFocusOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + CleanerOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + UsageCollectionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + QuinjetOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + QuinjetSessionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }

    public static let descriptors = registrations.map(\.descriptor)

    public static let userInterfaceActions: [RegisteredUserInterfaceAction] =
        registrations.flatMap { registration -> [RegisteredUserInterfaceAction] in
            switch registration.exposure {
            case let .userInterface(placements):
                placements.map {
                    RegisteredUserInterfaceAction(
                        operation: registration.descriptor, placement: $0)
                }
            case .commandLineOnly:
                []
            }
        }

    public static let commandLineOnly = registrations.filter {
        if case .commandLineOnly = $0.exposure { return true }
        return false
    }

    public static func descriptor(id: UserOperationID) -> UserOperationDescriptor? {
        descriptors.first { $0.id == id }
    }

    public static func descriptor(cli: [String]) -> UserOperationDescriptor? {
        descriptors.first { $0.cli == cli }
    }
}

public enum UserInterfaceActionCatalog {
    public static let actions = UserOperationCatalog.userInterfaceActions

    public static let presentationOnly = [
        UserInterfacePresentationState(
            surface: "Any scroll view", state: "scroll position",
            reason: "Scrolling changes only the current presentation and has no domain effect."),
        UserInterfacePresentationState(
            surface: "Navigation", state: "focus and selection",
            reason: "Focus and selection choose what the current window presents."),
        UserInterfacePresentationState(
            surface: "Disclosure groups", state: "folding",
            reason: "Folding changes visibility without reading or mutating domain state."),
        UserInterfacePresentationState(
            surface: "Search fields", state: "local filtering",
            reason: "Local filtering changes the visible collection without changing its data."),
        UserInterfacePresentationState(
            surface: "Sheets and popovers", state: "modal visibility",
            reason: "Opening or closing presentation chrome has no underlying operation."),
        UserInterfacePresentationState(
            surface: "Machine terminal", state: "mouse capture",
            reason: "Mouse capture controls input delivery within the current terminal view."),
        UserInterfacePresentationState(
            surface: "Clipboard panel", state: "history search filtering",
            reason: "Searching filters the entries already loaded into the clipboard panel."),
        UserInterfacePresentationState(
            surface: "Machine terminal", state: "terminal keyboard delivery",
            reason:
                "Typing sends input through the active terminal view without a discrete action."),
        UserInterfacePresentationState(
            surface: "Machine tab bar", state: "Files window visibility",
            reason: "Opening the Files window changes the visible application presentation."),
        UserInterfacePresentationState(
            surface: "Dashboard machines chip", state: "single-machine chart filter",
            reason:
                "Selecting one machine filters the usage charts already loaded in the dashboard."),
        UserInterfacePresentationState(
            surface: "Dashboard machines chip", state: "local-machine chart filter",
            reason: "Selecting local usage filters the charts without changing collected usage."),
    ]
}

private func userInterface(
    _ surface: String, _ action: String, _ exampleArguments: [String] = []
) -> UserOperationExposure {
    .userInterface([
        UserInterfaceActionPlacement(
            surface: surface, action: action, exampleArguments: exampleArguments)
    ])
}

private func commandLineOnly(_ reason: String) -> UserOperationExposure {
    .commandLineOnly(reason: reason)
}

private extension MachineControlOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface("Machine controls", "inspect available live controls", ["box"])
        case .brightness:
            userInterface("Machine controls", "set display brightness", ["box", "50"])
        case .volume:
            userInterface("Machine controls", "set output volume", ["box", "40"])
        case .mute:
            userInterface("Machine controls", "mute system audio", ["box", "on"])
        case .wifi:
            userInterface("Machine controls", "turn Wi-Fi off", ["box", "off", "--yes"])
        case .bluetooth:
            userInterface("Machine controls", "turn Bluetooth on", ["box", "on"])
        case .airplane:
            userInterface("Machine controls", "turn airplane mode on", ["box", "on", "--yes"])
        case .doNotDisturb:
            userInterface("Machine controls", "turn Do Not Disturb on", ["box", "on"])
        case .keyboardLight:
            userInterface("Machine controls", "set keyboard backlight brightness", ["box", "25"])
        }
    }
}

private extension ExtensionMutationOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .enable:
            userInterface("Extensions pane", "turn an extension on", ["clipboard"])
        case .disable:
            userInterface("Extensions pane", "turn an extension off", ["clipboard"])
        case .setup:
            userInterface("Extension setup", "prepare an extension for use", ["clipboard"])
        case .provisionTool:
            userInterface("Extension setup", "install a required CLI tool", ["yt-dlp"])
        }
    }
}

private extension CalendarEventOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            userInterface("Calendar agenda", "list upcoming events")
        case .open:
            userInterface("Calendar page", "open Calendar")
        case .join:
            userInterface("Calendar agenda", "join a meeting", ["event"])
        case .directions:
            userInterface("Calendar agenda", "open directions to a location", ["event"])
        }
    }
}

private extension ShelfItemOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .open:
            userInterface("Notch shelf", "open an item", ["1"])
        case .reveal:
            userInterface("Notch shelf", "reveal an item", ["1"])
        case .share:
            userInterface("Notch shelf", "share an item", ["1"])
        }
    }
}

private extension DownloadOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            userInterface("Download sheet", "list the download queue")
        case .status:
            userInterface("Download sheet", "summarize download lifecycle states")
        case .enqueue:
            userInterface("Download sheet", "start a download", ["https://x/y"])
        case .cancel:
            userInterface("Download sheet", "cancel running downloads")
        case .retry:
            userInterface("Download sheet", "retry failed items", ["--all"])
        case .remove:
            userInterface("Download sheet", "remove one item", ["1", "--yes"])
        case .clear:
            userInterface("Download sheet", "clear the history", ["--yes"])
        case .reveal:
            userInterface("Download sheet", "reveal a completed result", ["1"])
        case .open:
            userInterface("Download sheet", "open a completed result", ["1"])
        case .tool:
            userInterface("Download sheet", "update yt-dlp", ["--update"])
        }
    }
}

private extension MusicLibraryOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .favorite:
            userInterface("Music page", "favourite a track", ["song"])
        case .unfavorite:
            userInterface("Music page", "unfavourite a track", ["song"])
        case .reveal:
            userInterface("Music page", "reveal a track", ["song"])
        case .open:
            userInterface("Music page", "open the library")
        }
    }
}

private extension MusicTransportOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .play:
            userInterface("Music player", "play")
        case .pause:
            userInterface("Music player", "pause")
        case .stop:
            userInterface("Music player", "stop")
        case .toggle:
            userInterface("Music player", "play or pause with one key")
        case .next:
            userInterface("Music player", "skip forward")
        case .previous:
            userInterface("Music player", "skip back")
        case .start:
            userInterface("Music page", "click a track to play it", ["song"])
        case .seek:
            userInterface("Music footer", "drag the seek bar", ["0.5"])
        case .volume:
            userInterface("Music player", "change the volume", ["0.5"])
        case .shuffle:
            userInterface("Music footer", "toggle shuffle", ["on"])
        case .repeat:
            userInterface("Music footer", "toggle repeat", ["on"])
        case .status:
            userInterface("Music player", "inspect playback state")
        }
    }
}

private extension MusicCurrentOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .openCurrent:
            userInterface("Notch music", "open the current player")
        case .revealCurrent:
            userInterface("Notch music", "reveal the current track")
        }
    }
}

private extension PresenterRuntimeOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface("Presenter controls", "inspect presenter state")
        case .start:
            userInterface("Presenter controls", "start manual mode")
        case .stop:
            userInterface("Presenter controls", "stop manual mode")
        }
    }
}

private extension ConfigurationOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            commandLineOnly(
                "Settings panes read their known values instead of listing the catalog.")
        case .get:
            userInterface("Settings", "read a preference", ["theme"])
        case .set:
            userInterface("Settings", "change a preference", ["theme", "dim"])
        case .unset:
            userInterface("Settings", "restore a preference default", ["theme"])
        case .describe:
            commandLineOnly("Settings panes provide their own labels and do not open CLI metadata.")
        case .export:
            commandLineOnly("The app syncs settings through iCloud instead of exporting JSON.")
        case .import:
            commandLineOnly("The app restores settings through iCloud instead of importing JSON.")
        }
    }
}

private extension PermissionOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface("Permissions pane", "inspect permission state")
        case .request:
            userInterface("Permissions pane", "raise a macOS permission prompt", ["calendar"])
        case .refresh:
            userInterface("Permissions pane", "re-read the real permission state")
        case .settings:
            userInterface(
                "Permissions pane", "open the relevant System Settings pane", ["calendar"])
        }
    }
}

private extension ColorPickerOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .pick:
            userInterface("Colour picker", "open the system loupe")
        }
    }
}

private extension ColorSwatchOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .copy:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Color Picker menu", action: "copy a recent colour",
                    exampleArguments: ["1"]),
                UserInterfaceActionPlacement(
                    surface: "Color Picker settings", action: "copy a swatch in one format",
                    exampleArguments: ["1", "--format", "hex"]),
            ])
        }
    }
}

private extension CompanionSettingsOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .syncGithub:
            userInterface("Companion", "sync github activity", ["github"])
        case .exportData:
            userInterface(
                "Companion settings", "export the memory as a bundle", ["/tmp/backup"])
        case .importData:
            userInterface(
                "Companion settings", "restore a memory bundle", ["/tmp/backup"])
        case .wipe:
            userInterface("Companion settings", "wipe the whole memory", ["--yes"])
        case .dbReindex:
            userInterface(
                "Companion settings", "drop and rebuild the search index", ["--yes"])
        case .dbRebuildDerived:
            userInterface(
                "Companion settings", "rebuild everything derived", ["--yes"])
        case .connectorsSet:
            userInterface(
                "Companion settings", "store a github or notion token",
                ["--github", "gho_x"])
        case .connectorsImport:
            userInterface(
                "Companion settings", "import a calendar, music or youtube export",
                ["music", "./export.json"])
        case .reasonSet:
            userInterface(
                "Companion settings", "change the reasoner or its api key",
                ["--provider", "anthropic", "--api-key", "sk-x"])
        case .reasonTest:
            userInterface("Companion settings", "test the reasoner")
        }
    }
}

private extension ClipboardOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .stats:
            userInterface(
                "Clipboard settings", "see how many entries and how big")
        case .copy:
            userInterface("Clipboard panel", "click an entry to copy it", ["1"])
        case .pin:
            userInterface("Clipboard panel", "pin an entry", ["1"])
        case .unpin:
            userInterface("Clipboard panel", "unpin an entry", ["1"])
        case .remove:
            userInterface("Clipboard panel", "delete an entry", ["1", "--yes"])
        }
    }
}

private extension AttentionFocusOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .start:
            userInterface(
                "Attention focus card", "start a focus session",
                ["--for", "25m", "--name", "Focus"])
        case .stop:
            userInterface("Attention focus card", "finish a focus session")
        }
    }
}

private extension CleanerOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .scan:
            userInterface(
                "Cleaner drive picker", "sweep a folder for project junk",
                ["--root", "~/code"])
        case .clean:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Cleaner card", action: "reclaim the scanned caches"),
                UserInterfaceActionPlacement(
                    surface: "Cleaner card", action: "clean one category",
                    exampleArguments: ["--category", "npm", "--yes"]),
            ])
        }
    }
}

private extension UsageCollectionOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .limitsRefresh:
            userInterface("Rate limit cards", "refresh the limits now", ["--refresh"])
        case .refresh:
            userInterface("Dashboard", "re-collect agent usage")
        case .machineEnable:
            userInterface(
                "Dashboard machines menu", "count a machine's agent usage too", ["box"])
        case .machineDisable:
            userInterface("Dashboard machines menu", "stop counting a machine", ["box"])
        case .machineCollect:
            userInterface("Dashboard machines menu", "collect from the machines now")
        case .machineForget:
            userInterface(
                "Dashboard machines menu", "drop what a machine already gave", ["box"])
        }
    }
}

private extension QuinjetOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .projects:
            userInterface("Quinjet page", "list recent review projects")
        case .worktrees:
            userInterface("Quinjet project picker", "list project worktrees", ["/tmp/project"])
        case .open:
            userInterface(
                "Quinjet project picker", "prepare a review launch", ["/tmp/project"])
        case .launch:
            userInterface("Quinjet project picker", "launch a review session", ["/tmp/project"])
        }
    }
}

private extension QuinjetSessionOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface("Quinjet workspace", "inspect the active review session")
        case .sessions:
            userInterface("Quinjet tab bar", "list open native review sessions")
        case .create:
            userInterface("Quinjet tab bar", "create a native review session")
        case .focus:
            userInterface("Quinjet tab bar", "select and focus a review session", ["1"])
        case .close:
            userInterface("Quinjet tab bar", "close a review session", ["1", "--yes"])
        case .restart:
            userInterface("Quinjet workspace", "restart the active review", ["1"])
        case .switchWorktree:
            userInterface(
                "Quinjet worktree picker", "switch an open session", ["1", "/tmp/worktree"])
        }
    }
}
