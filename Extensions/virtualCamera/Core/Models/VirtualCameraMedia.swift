import EdithExtensionSupport
import Foundation

public enum VirtualCameraMediaKind: String, Codable, CaseIterable, Sendable {
    case camera
    case video
    case screen
}

public enum VirtualCameraPlayback: String, Codable, Sendable {
    case playing
    case paused
    case stopped
}

public struct VirtualCameraMedia: Codable, Equatable, Sendable {
    public var kind: VirtualCameraMediaKind
    public var path: String?
    public var screenID: String?
    public var playback: VirtualCameraPlayback
    public var loop: Bool
    public var audioEnabled: Bool

    public init(
        kind: VirtualCameraMediaKind = .camera, path: String? = nil, screenID: String? = nil,
        playback: VirtualCameraPlayback = .playing, loop: Bool = true, audioEnabled: Bool = false
    ) {
        self.kind = kind
        self.path = path
        self.screenID = screenID
        self.playback = playback
        self.loop = loop
        self.audioEnabled = audioEnabled
    }
}
