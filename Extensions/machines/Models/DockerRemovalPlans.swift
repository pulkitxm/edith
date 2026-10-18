import Foundation

struct PrunePlan: Identifiable, Equatable {
    let kind: DockerPruneTarget

    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .images: return "Prune unused images?"
        case .volumes: return "Prune unused volumes?"
        case .networks: return "Prune unused networks?"
        case .builder: return "Prune the build cache?"
        case .system: return "Prune unused Docker objects?"
        }
    }

    var detail: String {
        switch kind {
        case .images:
            return "Every image no container is using is deleted on the machine and has to be "
                + "pulled again."
        case .volumes:
            return "Every volume no container is using is deleted on the machine, along with the "
                + "data inside it. This cannot be undone."
        case .networks: return "Every network no container is attached to is deleted."
        case .builder: return "The build cache is deleted, so the next build starts from scratch."
        case .system:
            return "Stopped containers, unused networks, dangling images, and build cache are "
                + "deleted. Volumes are left alone."
        }
    }
}

enum DockerObjectRemovalPlan: Identifiable, Equatable {
    case image(String)
    case volume(String)

    var id: String {
        switch self {
        case let .image(reference): "image:\(reference)"
        case let .volume(name): "volume:\(name)"
        }
    }

    var title: String {
        switch self {
        case .image: "Remove this image?"
        case .volume: "Remove this volume?"
        }
    }

    var detail: String {
        switch self {
        case let .image(reference):
            "\(reference) is deleted from the machine and has to be pulled again."
        case let .volume(name):
            "\(name) and all of its data are deleted. This cannot be undone."
        }
    }

    var operation: DockerLifecycleOperation {
        switch self {
        case .image: .removeImage
        case .volume: .removeVolume
        }
    }

    var target: DockerLifecycleTarget {
        switch self {
        case let .image(reference): .image(reference, force: false)
        case let .volume(name): .volume(name)
        }
    }

    var busyID: String {
        switch self {
        case let .image(reference): reference
        case let .volume(name): name
        }
    }
}
