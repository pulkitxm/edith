import Foundation

extension VideoEditorService {
    public struct ProjectDescription: Codable, Sendable {
        public let version: Int
        public let path: String
        public let projectID: String
        public let title: String
        public let revision: String
        public let settings: VideoSettings
        public let clipIDs: [String]
        public let audioIDs: [String]
        public let captionIDs: [String]
        public let assetCount: Int
    }

    public static func describe(_ url: URL) throws -> ProjectDescription {
        let snapshot = try readProject(url)
        let project = snapshot.project
        return ProjectDescription(
            version: 1, path: url.standardizedFileURL.path,
            projectID: project.id, title: project.title,
            revision: snapshot.revision.fingerprint.hexDigest, settings: project.videoSettings,
            clipIDs: project.clips.map(\.id), audioIDs: project.audioTracks.map(\.id),
            captionIDs: project.annotations.filter { $0.type == "text" }.map(\.id),
            assetCount: project.assets.count)
    }
}
