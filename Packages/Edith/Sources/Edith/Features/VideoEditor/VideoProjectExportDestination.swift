import Foundation

enum VideoProjectExportDestination {
    enum DestinationError: LocalizedError, Equatable {
        case projectDependency

        var errorDescription: String? {
            "Choose an export destination that is not the project, its media, or a recording sidecar."
        }
    }

    static func validate(_ destination: URL, project: VideoProject) throws {
        var dependencies = project.fileURL.map { [$0] } ?? []
        for asset in project.assets {
            let paths = [
                asset.raw["originalPath"] as? String,
                asset.raw["edithAudioPath"] as? String,
                asset.raw["edithSourceImagePath"] as? String,
                asset.cameraTrack?["sourcePath"] as? String,
            ]
            for path in paths.compactMap({ $0 }) where !path.isEmpty {
                dependencies.append(URL(fileURLWithPath: path))
                dependencies.append(URL(fileURLWithPath: path + ".cursor.json"))
                dependencies.append(URL(fileURLWithPath: path + ".session.json"))
            }
        }
        let wallpaper = project.backgroundColor
        if !wallpaper.isEmpty, !wallpaper.hasPrefix("#") {
            dependencies.append(URL(fileURLWithPath: wallpaper))
        }
        for annotation in project.annotations where annotation.type == "image" {
            let content = annotation.raw["imageContent"] as? String ?? annotation.text
            guard !content.isEmpty else { continue }
            if content.hasPrefix("data:"),
                Data(base64Encoded: String(content.split(separator: ",").last ?? "")) != nil
            {
                continue
            }
            dependencies.append(URL(fileURLWithPath: content))
        }
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        let identity = fileIdentity(destination)
        for dependency in dependencies {
            if dependency.resolvingSymlinksInPath().standardizedFileURL == resolved {
                throw DestinationError.projectDependency
            }
            if let identity, let dependencyIdentity = fileIdentity(dependency),
                identity.isEqual(dependencyIdentity)
            {
                throw DestinationError.projectDependency
            }
        }
    }

    private static func fileIdentity(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
            .fileResourceIdentifier as? NSObject
    }
}
