import EdithExtensionFiles
import EdithExtensionSupport
import Foundation

public enum RemoteFileOperation: String, CaseIterable, Sendable {
    case preview
    case launch
    case reveal
    case download

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .preview:
            descriptor("preview", "Preview a remote text file.", effect: .read)
        case .launch:
            descriptor("launch", "Open a remote file in its default Mac app.", effect: .interactive)
        case .reveal:
            descriptor("reveal", "Reveal a remote file in Finder.", effect: .interactive)
        case .download:
            descriptor("get", "Download a remote file.", effect: .write)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.files.\(rawValue)"), summary: summary,
            cli: ["machines", "files", verb], effect: effect)
    }
}

public enum PortForwardBrowserOperation: CaseIterable, Sendable {
    case open

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.forwards.open"),
            summary: "Open a forwarded service in the browser.",
            cli: ["machines", "forwards", "open"], effect: .interactive)
    }
}

public enum DockerBrowserOperation: CaseIterable, Sendable {
    case open

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.docker.open"),
            summary: "Open a published container port in the browser.",
            cli: ["machines", "docker", "open"], effect: .interactive)
    }
}

public enum MountedFileSystemOperation: CaseIterable, Sendable {
    case reveal

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.mount.reveal"),
            summary: "Reveal a mounted machine file system in Finder.",
            cli: ["machines", "mount-reveal"], effect: .interactive)
    }
}

public enum PortForwardBrowserOperationExecution {
    public static func url(forward: PortForward) -> URL? {
        LocalBrowserOperationExecution.url(port: forward.localPort)
    }
}

public enum LocalBrowserOperationExecution {
    public static func url(port: Int) -> URL? {
        URL(string: "http://localhost:\(port)")
    }

    public static func publishedPorts(
        in container: DockerContainer, matching requestedPort: Int?
    ) -> [DockerPortMapping] {
        DockerBrowserOperationExecution.publishedPorts(
            in: container, matching: requestedPort)
    }
}
