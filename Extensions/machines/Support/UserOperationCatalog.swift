import EdithExtensionSupport

public enum UserOperationCatalog {
    public static let registrations: [RegisteredUserOperation] =
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
        + DockerLifecycleOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + WorkspaceOperation.allCases.map {
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
        + PortForwardBrowserOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + DockerBrowserOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MountedFileSystemOperation.allCases.map {
            RegisteredUserOperation(descriptor: $0.descriptor, exposure: $0.interfaceExposure)
        }
        + MachineFileOperation.allCases.map {
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
        case .caffeinate:
            userInterface("Machine controls", "prevent automatic sleep", ["box", "on"])
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

private extension MachineFileOperation {
    var interfaceExposure: UserOperationExposure {
        userInterface(placement.surface, placement.action, placement.exampleArguments)
    }
}

public enum UserInterfaceActionCatalog {
    public static let actions = UserOperationCatalog.userInterfaceActions
}
