import EdithCore

public enum UserOperationCatalog {
    private static let machineRegistrations: [RegisteredUserOperation] =
        MachineControlOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineThermalOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineExecOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineMountOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineBroadcastOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineTerminalBroadcastOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + DockerLifecycleOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineMutationOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachinePowerOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineConnectionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + DockerDetailOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + SavedSnippetOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineForwardOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineSnippetOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineServiceOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineProcessOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineDockerPauseOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }

    private static let applicationRegistrations: [RegisteredUserOperation] =
        AppInspectionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ExtensionInspectionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ExtensionMutationOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + AppRuntimeOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + CalendarEventOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ShelfItemOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ShelfMutationOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + DownloadOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MusicLibraryOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MusicLibraryContentOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MusicFolderSelectionOperation.allCases.map {
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
        + LidAwakeOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + AudioControlOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }

    private static let featureRegistrations: [RegisteredUserOperation] =
        UsageProjectOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + ConfigurationOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + TerminalToolingOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + PermissionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + RunningAppOperation.allCases.map {
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
        + WorkspaceOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }

    private static let remoteFileRegistrations: [RegisteredUserOperation] =
        UsageCollectionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + QuinjetOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + QuinjetSessionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + RemoteFileOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + RemoteDirectoryOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + RemoteTransferOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }

    private static let remoteActionRegistrations: [RegisteredUserOperation] = {
        var registrations = CompanionChatLibraryOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        registrations += MachineFileOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        registrations += CompanionMindRuntimeOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        registrations += HerdrSessionOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        registrations += PortForwardBrowserOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        registrations += DockerBrowserOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        registrations += MountedFileSystemOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        registrations += HerdrOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        return registrations
    }()

    public static let registrations =
        machineRegistrations + applicationRegistrations + featureRegistrations
        + remoteFileRegistrations + remoteActionRegistrations

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

private extension MachineThermalOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface("Machine cooling", "inspect thermal profiles", ["box"])
        case .set:
            userInterface(
                "Machine cooling", "switch thermal profiles", ["box", "performance"])
        }
    }
}

private extension AppInspectionOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .info:
            userInterface("About pane", "read the app version")
        case .diagnostics:
            userInterface(
                "Developer panel", "read process uptime and idle wakeups")
        case .paths:
            commandLineOnly("The app opens named paths directly instead of listing the catalog.")
        case .links:
            commandLineOnly("The app opens named links directly instead of listing the catalog.")
        case .openPath:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "iCloud settings", action: "open the app data folder",
                    exampleArguments: ["app-data"]),
                UserInterfaceActionPlacement(
                    surface: "iCloud settings", action: "open the iCloud folder",
                    exampleArguments: ["icloud"]),
                UserInterfaceActionPlacement(
                    surface: "Developer panel", action: "open the usage data folder",
                    exampleArguments: ["data"]),
                UserInterfaceActionPlacement(
                    surface: "Developer panel", action: "reveal the refresh log",
                    exampleArguments: ["refresh-log"]),
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "open the music folder",
                    exampleArguments: ["music"]),
            ])
        case .openLink:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "About pane", action: "open the source repository",
                    exampleArguments: ["repository"]),
                UserInterfaceActionPlacement(
                    surface: "Navigation sidebar", action: "open the creator profile",
                    exampleArguments: ["creator"]),
                UserInterfaceActionPlacement(
                    surface: "About pane", action: "open a contributor profile",
                    exampleArguments: ["contributor:octo"]),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "open an extension guide",
                    exampleArguments: ["extension-doc:usage:guide"]),
            ])
        }
    }
}

private extension MachineExecOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface(
            "Docker window", "open a shell in a container",
            ["box", "api"])
    }
}

private extension MachineMountOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .mount:
            userInterface("Machine tools", "mount the machine's disk on this Mac", ["box"])
        case .unmount:
            userInterface("Machine tools", "unmount the machine's disk", ["box"])
        }
    }
}

private extension MachineBroadcastOperation {
    var interfaceExposure: UserOperationExposure {
        .commandLineOnly(
            reason:
                "Fleet broadcast runs separate SSH commands and has no matching application control."
        )
    }
}

private extension MachineTerminalBroadcastOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface(
            "Terminal broadcast bar", "send one line to every pane",
            ["box", "--", "uptime"])
    }
}

private extension MachineMutationOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .add:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Machines", action: "add a machine",
                    exampleArguments: ["box", "--host", "h"]),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "add a machine",
                    exampleArguments: ["box", "--host", "h"]),
                UserInterfaceActionPlacement(
                    surface: "Add machine sheet", action: "store a login password",
                    exampleArguments: ["box", "--host", "h", "--password-stdin"]),
            ])
        case .edit:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Machines", action: "edit a machine", exampleArguments: ["box"]),
                UserInterfaceActionPlacement(
                    surface: "Add machine sheet", action: "store a key passphrase",
                    exampleArguments: ["box", "--key-passphrase-stdin"]),
                UserInterfaceActionPlacement(
                    surface: "Add machine sheet", action: "store a sudo password",
                    exampleArguments: ["box", "--sudo-password-stdin"]),
                UserInterfaceActionPlacement(
                    surface: "Add machine sheet", action: "forget the stored sudo password",
                    exampleArguments: ["box", "--forget-sudo-password"]),
            ])
        case .remove:
            userInterface("Machines", "delete a machine", ["box"])
        }
    }
}

private extension MachinePowerOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .reboot:
            userInterface("Machine header", "restart the machine", ["box", "--yes"])
        case .shutdown:
            userInterface("Machine header", "shut the machine down", ["box", "--yes"])
        case .wake:
            userInterface("Machine header", "wake the machine", ["box"])
        }
    }
}

private extension MachineConnectionOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .connect:
            userInterface("Machines", "open the shared connection", ["box"])
        case .disconnect:
            userInterface("Machines", "close the shared connection", ["box"])
        }
    }
}

private extension DockerDetailOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .inspect:
            userInterface("Docker details", "inspect a container", ["box", "api"])
        case .top:
            userInterface("Docker details", "read container processes", ["box", "api"])
        }
    }
}

private extension SavedSnippetOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface("Machine tools", "run a saved snippet", ["box", "1"])
    }
}

private extension MachineForwardOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .add:
            userInterface(
                "Machine tools", "save a port forward",
                ["box", "--local", "8080", "--remote", "80"])
        case .remove:
            userInterface("Machine tools", "delete a port forward", ["box", "1"])
        case .enable:
            userInterface("Machine tools", "switch a port forward on", ["box", "1"])
        case .disable:
            userInterface("Machine tools", "switch a port forward off", ["box", "1"])
        }
    }
}

private extension MachineSnippetOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .add:
            userInterface(
                "Machine tools", "save a snippet", ["box", "logs", "journalctl"])
        case .remove:
            userInterface("Machine tools", "delete a snippet", ["box", "1"])
        }
    }
}

private extension MachineServiceOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .start:
            userInterface(
                "Machine tools", "start a systemd unit", ["box", "nginx.service"])
        case .stop:
            userInterface(
                "Machine tools", "stop a systemd unit", ["box", "nginx.service"])
        case .restart:
            userInterface(
                "Machine tools", "restart a systemd unit", ["box", "nginx.service"])
        }
    }
}

private extension MachineProcessOperation {
    var interfaceExposure: UserOperationExposure {
        .userInterface([
            UserInterfaceActionPlacement(
                surface: "Machine processes", action: "end a process with SIGTERM",
                exampleArguments: ["box", "42"]),
            UserInterfaceActionPlacement(
                surface: "Machine processes", action: "force kill a process",
                exampleArguments: ["box", "42", "--signal", "KILL", "--yes"]),
        ])
    }
}

private extension MachineDockerPauseOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .pause:
            userInterface("Docker window", "pause a container", ["box", "api"])
        case .unpause:
            userInterface("Docker window", "unpause a container", ["box", "api"])
        }
    }
}

private extension ExtensionInspectionOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            userInterface("Extensions pane", "browse registered extensions")
        case .info:
            userInterface(
                "Extension settings", "inspect metadata and requirements", ["clipboard"])
        case .status:
            userInterface("Extension settings", "inspect live readiness", ["clipboard"])
        case .verify:
            userInterface("Extension settings", "check readiness again", ["clipboard"])
        case .doctor:
            userInterface(
                "Extension settings", "inspect failures and recovery guidance", ["clipboard"])
        }
    }
}

private extension DockerLifecycleOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .start:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Docker window", action: "start a container",
                    exampleArguments: ["box", "api"]),
                UserInterfaceActionPlacement(
                    surface: "Docker group header",
                    action: "start the stopped containers in the group",
                    exampleArguments: ["box", "api", "db"]),
            ])
        case .stop:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Docker window", action: "stop a container",
                    exampleArguments: ["box", "api"]),
                UserInterfaceActionPlacement(
                    surface: "Docker group header",
                    action: "stop the running containers in the group",
                    exampleArguments: ["box", "api", "db"]),
            ])
        case .restart:
            userInterface("Docker window", "restart a container", ["box", "api"])
        case .removeContainer:
            userInterface(
                "Docker window", "remove a container", ["box", "api", "--yes"])
        case .removeImage:
            userInterface(
                "Docker window", "remove an image", ["box", "nginx", "--yes"])
        case .removeVolume:
            userInterface("Docker window", "remove a volume", ["box", "data"])
        case .prune:
            userInterface("Docker window", "prune unused objects", ["box", "images"])
        }
    }
}

private extension WorkspaceOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            userInterface("Workspace view", "list saved layouts")
        case .split:
            userInterface("Workspace pane menu", "split a pane", ["1", "box"])
        case .close:
            userInterface("Workspace pane menu", "close a pane", ["1"])
        case .point:
            userInterface("Workspace tab strip", "point a pane at another machine", ["1", "box"])
        case .equalize:
            userInterface("Workspace toolbar", "even out the panes")
        case .create:
            userInterface(
                "Workspace toolbar", "apply a layout preset",
                ["box", "--screen", "terminal"])
        case .use:
            userInterface("Workspace picker", "switch to another layout", ["a"])
        case .rename:
            userInterface("Workspace picker", "rename a layout", ["a", "b"])
        case .remove:
            userInterface("Workspace picker", "delete a layout", ["a"])
        }
    }
}

private extension ExtensionMutationOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .enable:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Extensions pane", action: "turn an extension on",
                    exampleArguments: ["clipboard"]),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "turn the extension on",
                    exampleArguments: ["clipboard"]),
                UserInterfaceActionPlacement(
                    surface: "Extension permission sheet",
                    action: "enable after required permissions are granted",
                    exampleArguments: ["clipboard"]),
            ])
        case .disable:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Extensions pane", action: "turn an extension off",
                    exampleArguments: ["clipboard"]),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "turn the extension off",
                    exampleArguments: ["clipboard"]),
            ])
        case .setup:
            userInterface("Extension setup", "prepare an extension for use", ["clipboard"])
        case .provisionTool:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Extension setup", action: "install a required CLI tool",
                    exampleArguments: ["yt-dlp"]),
                UserInterfaceActionPlacement(
                    surface: "Extension sheet", action: "install a required CLI tool",
                    exampleArguments: ["yt-dlp"]),
            ])
        }
    }
}

private extension AppRuntimeOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .cleanKeys:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Menu bar", action: "lock the keyboard to clean it"),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "lock the keyboard to clean it"),
            ])
        case .testNotification:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Settings", action: "send a test notification"),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "send a test notification"),
            ])
        case .open:
            userInterface("Menu bar", "open the panel")
        case .quit:
            userInterface("Menu bar", "quit Edith", ["--yes"])
        case .checkUpdates:
            userInterface("About pane", "check for updates")
        case .updateHistory:
            userInterface("Update schedule sheet", "read the check history")
        case .relaunch:
            userInterface("Permissions pane", "relaunch after granting", ["--yes"])
        case .clearUpdateHistory:
            userInterface("Update schedule sheet", "clear the check history", ["--yes"])
        case .reveal:
            commandLineOnly(
                "The running app reveals its own sections only when another process asks it to.")
        case .snapshot:
            commandLineOnly(
                "Window snapshots are an external automation surface rather than an in-app action.")
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
            userInterface("Notch shelf", "open selected items", ["1", "2"])
        case .reveal:
            userInterface("Notch shelf", "reveal selected items", ["1", "2"])
        case .share:
            userInterface("Notch shelf", "share selected items", ["1", "2"])
        }
    }
}

private extension ShelfMutationOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .add:
            userInterface("Notch shelf", "drop a file onto the shelf", ["./file"])
        case .addText:
            userInterface("Notch shelf", "drop text onto the shelf", ["note"])
        case .update:
            userInterface(
                "Notch shelf", "move an item on the canvas",
                ["1", "--x", "120", "--y", "60"])
        case .remove:
            userInterface(
                "Notch shelf", "take selected items off the shelf", ["1", "2", "--yes"])
        case .clear:
            commandLineOnly(
                "The shelf UI deletes selected items but has no action that empties the shelf.")
        case .purge:
            userInterface("Notch shelf", "remove expired items", ["oneDay", "--yes"])
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
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Download sheet", action: "cancel running downloads"),
                UserInterfaceActionPlacement(
                    surface: "Download queue row", action: "cancel one active download",
                    exampleArguments: ["1"]),
            ])
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
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "open the library"),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "open the music folder"),
            ])
        }
    }
}

private extension MusicLibraryContentOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            userInterface("Music page", "browse the library")
        case .rescan:
            userInterface("Music page", "rescan the library")
        case .createFolder:
            userInterface("Music page", "make a folder", ["Chill"])
        case .move:
            userInterface("Music page", "move a track into a folder", ["song", "Chill"])
        case .rename:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "rename a track",
                    exampleArguments: ["song", "New"]),
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "rename a folder",
                    exampleArguments: ["--folder", "Chill", "Calm"]),
            ])
        case .remove:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "move a track to the Trash",
                    exampleArguments: ["song", "--yes"]),
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "move a folder to the Trash",
                    exampleArguments: ["--folder", "Chill", "--yes"]),
            ])
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
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "click a track to play it",
                    exampleArguments: ["song"]),
                UserInterfaceActionPlacement(
                    surface: "Music page", action: "play a whole folder",
                    exampleArguments: ["--folder", "Chill"]),
            ])
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

private extension LidAwakeOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface("Lid Awake controls", "inspect runtime state")
        case .on:
            userInterface(
                "Lid Awake controls", "keep running with the lid closed", ["--yes"])
        case .off:
            userInterface("Lid Awake controls", "restore normal lid-close sleep")
        case .battery:
            userInterface(
                "Lid Awake settings", "set the low-battery pause floor", ["20"])
        case .restoreOnQuit:
            userInterface(
                "Lid Awake settings", "leave sleep disabled after quitting", ["false", "--yes"])
        }
    }
}

private extension UsageProjectOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            userInterface("Dashboard repository drilldown", "list repository usage")
        case .show:
            userInterface(
                "Dashboard repository drilldown", "show one repository and its folders",
                ["edith"])
        case .openRepository:
            userInterface(
                "Dashboard repository drilldown", "open a repository", ["edith"])
        case .copyRepositoryLink:
            userInterface(
                "Dashboard repository drilldown", "copy a repository link", ["edith"])
        case .copyChatID:
            userInterface(
                "Dashboard repository drilldown", "copy a chat identifier", ["abc"])
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
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Settings", action: "change a preference",
                    exampleArguments: ["theme", "dim"]),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "change an extension preference",
                    exampleArguments: ["musicCrossfadeEnabled", "true"]),
                UserInterfaceActionPlacement(
                    surface: "Companion settings", action: "point at another companion",
                    exampleArguments: [
                        "companionEndpoint", "http://127.0.0.1:4820",
                    ]),
                UserInterfaceActionPlacement(
                    surface: "Quinjet terminal menu", action: "select the external terminal",
                    exampleArguments: ["quinjetTerminal", "cmux"]),
                UserInterfaceActionPlacement(
                    surface: "Quinjet theme menu", action: "select the review theme",
                    exampleArguments: ["quinjetTheme", "tokyo-night"]),
            ])
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

private extension MusicFolderSelectionOperation {
    var interfaceExposure: UserOperationExposure {
        .userInterface([
            UserInterfaceActionPlacement(
                surface: "Music page", action: "choose the music folder",
                exampleArguments: ["~/Music"]),
            UserInterfaceActionPlacement(
                surface: "Extension settings", action: "choose the music folder",
                exampleArguments: ["~/Music"]),
        ])
    }
}

private extension HerdrSessionOperation {
    var interfaceExposure: UserOperationExposure {
        .userInterface([
            UserInterfaceActionPlacement(
                surface: "Herdr board",
                action: "list live sessions on this Mac and SSH machines"),
            UserInterfaceActionPlacement(
                surface: "Extension settings", action: "check live Herdr sessions"),
        ])
    }
}

private extension PermissionOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface("Permissions pane", "inspect permission state")
        case .request:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Permissions pane", action: "raise a macOS permission prompt",
                    exampleArguments: ["calendar"]),
                UserInterfaceActionPlacement(
                    surface: "Extension settings", action: "raise a macOS permission prompt",
                    exampleArguments: ["calendar"]),
                UserInterfaceActionPlacement(
                    surface: "Extension permission sheet",
                    action: "raise a macOS permission prompt", exampleArguments: ["calendar"]),
            ])
        case .refresh:
            userInterface("Permissions pane", "re-read the real permission state")
        case .settings:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Permissions pane", action: "open the relevant System Settings pane",
                    exampleArguments: ["calendar"]),
                UserInterfaceActionPlacement(
                    surface: "Extension settings",
                    action: "open the relevant System Settings pane",
                    exampleArguments: ["calendar"]),
                UserInterfaceActionPlacement(
                    surface: "Extension permission sheet",
                    action: "open the relevant System Settings pane",
                    exampleArguments: ["calendar"]),
            ])
        }
    }
}

private extension RunningAppOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            userInterface("System page", "inspect running applications")
        case .quit:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "System page", action: "quit one app",
                    exampleArguments: ["Safari", "--yes"]),
                UserInterfaceActionPlacement(
                    surface: "System page", action: "quit all apps",
                    exampleArguments: ["--all", "--yes"]),
            ])
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
        case .clear:
            userInterface(
                "Clipboard panel", "clear unpinned entries", ["--keep-pinned", "--yes"])
        }
    }
}

private extension TerminalToolingOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            userInterface(
                "Terminal settings", "inspect command-line tools and shell completions",
                ["--json"])
        case .install:
            userInterface("Terminal settings", "install command-line tools")
        case .remove:
            userInterface("Terminal settings", "remove command-line tools")
        case .completionInstall:
            userInterface("Terminal settings", "install shell completions")
        case .fallbackSource:
            userInterface("Terminal settings", "copy the fallback completion source line")
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

private extension RemoteFileOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .preview:
            userInterface(
                "Machine finder preview", "read a text preview", ["box", "/tmp/notes.txt"])
        case .launch:
            userInterface(
                "Machine finder", "open a remote file in its default app",
                ["box", "/tmp/notes.txt"])
        case .reveal:
            userInterface(
                "Machine finder", "reveal a downloaded file in Finder",
                ["box", "/tmp/notes.txt"])
        case .download:
            userInterface("Machine finder", "download a remote file", ["box", "/etc/hosts"])
        }
    }
}

private extension RemoteDirectoryOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .list:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Machine finder", action: "list a folder",
                    exampleArguments: ["box", "/a"]),
                UserInterfaceActionPlacement(
                    surface: "Quinjet machine picker", action: "browse a folder on another machine",
                    exampleArguments: ["build", "/tmp"]),
            ])
        case .create:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Machine finder", action: "create a folder",
                    exampleArguments: ["box", "/a/new"]),
                UserInterfaceActionPlacement(
                    surface: "Machine finder", action: "make a folder",
                    exampleArguments: ["box", "/a"]),
            ])
        }
    }
}

private extension RemoteTransferOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .downloadSelection:
            userInterface(
                "Machine finder", "download several selected files",
                ["box", "/etc/hosts", "/etc/services", "--to", "/tmp", "--dry-run"])
        case .transferBetweenMachines:
            userInterface(
                "Machine finder", "drag files between machines",
                ["box", "server", "/tmp/a", "--into", "/srv", "--dry-run"])
        case .uploadFile:
            userInterface(
                "Machine finder", "upload a local file", ["box", "./x", "/tmp/x"])
        case .copyWithinMachine:
            userInterface("Machine finder", "copy files", ["box", "/a", "/b"])
        case .moveWithinMachine:
            userInterface("Machine finder", "cut and paste files", ["box", "/a", "/b"])
        }
    }
}

private extension PortForwardBrowserOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface("Machine tools", "open a forwarded service", ["box", "1"])
    }
}

private extension DockerBrowserOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface(
            "Docker window", "open a published port in the browser",
            ["box", "api", "--port", "8080"])
    }
}

private extension MountedFileSystemOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface("Machine tools", "reveal the mounted disk", ["box"])
    }
}

private extension HerdrOperation {
    var interfaceExposure: UserOperationExposure {
        switch self {
        case .command:
            userInterface(
                "Herdr session tab", "copy the attach command for a pane", ["w3:p1N"])
        case .attach:
            userInterface("Herdr board", "attach to a live pane", ["w3:p1N"])
        }
    }
}

private extension CompanionChatLibraryOperation {
    var interfaceExposure: UserOperationExposure {
        .userInterface(
            placements.map {
                UserInterfaceActionPlacement(
                    surface: $0.surface, action: $0.action,
                    exampleArguments: $0.exampleArguments)
            })
    }
}
private extension MachineFileOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface(placement.surface, placement.action, placement.exampleArguments)
    }
}

private extension CompanionMindRuntimeOperation {
    var interfaceExposure: UserOperationExposure {
        .userInterface(placements)
    }
}
