import Foundation

public enum MeetingVoicePreset: String, Codable, CaseIterable, Sendable {
    case natural
    case deep
    case bright
    case cinematic
    case radio
    case telephone
    case robot
    case alien
    case echo

    public var title: String { rawValue.capitalized }
    public var pitch: Float {
        switch self {
        case .deep: -600
        case .bright: 500
        case .cinematic: -300
        case .alien: 800
        default: 0
        }
    }
}

public struct MeetingAudioClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var path: String
    public var start: Double = 0
    public var end: Double?
    public var gain: Float = 1
    public var speech: Bool = true
}

public struct MeetingAudioState: Codable, Equatable, Sendable {
    public var enabled = false
    public var inputID: String?
    public var outputID: String?
    public var muted = false
    public var micGain: Float = 1
    public var clipsGain: Float = 1
    public var sourceGain: Float = 1
    public var preset: MeetingVoicePreset = .natural
    public var pitch: Float = 0
    public var reverb: Float = 0
    public var delay: Float = 0
    public var clips: [MeetingAudioClip] = []
    public var voiceModels: [MeetingVoiceModel] = []
    public var voiceModelID: UUID?
    public var voiceTranspose: Float = 0

    public init() {}
}

public enum MeetingAudioRequest: Codable, Equatable, Sendable {
    case status
    case enable(Bool)
    case input(String)
    case output(String)
    case mute(Bool)
    case voice(MeetingVoicePreset)
    case levels(mic: Float?, clips: Float?, source: Float?)
    case effects(pitch: Float?, reverb: Float?, delay: Float?)
    case importClip(name: String, path: String, speech: Bool)
    case editClip(name: String, start: Double, end: Double?, gain: Float)
    case recordClip(String)
    case finishClip
    case playClip(String)
    case stopClips
    case removeClip(String)
    case importVoice(name: String, encoder: String, voice: String)
    case selectVoice(String)
    case modelPitch(Float)
    case removeVoice(String)
}

public struct MeetingAudioStatus: Codable, Equatable, Sendable {
    public var running = false
    public var inputName: String?
    public var outputName: String?
    public var recordingName: String?
    public var playing: [String] = []
    public var failure: String?
    public var sourceFailure: String?
    public init() {}
}

public enum MeetingAudioLibrary {
    public static var directory: URL {
        DataRoot.virtualCamera.appendingPathComponent("audio", isDirectory: true)
    }

    public static func clip(_ name: String, in state: MeetingAudioState) throws -> MeetingAudioClip
    {
        guard
            let clip = state.clips.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name
            })
        else {
            throw error("No audio clip named \(name).")
        }
        return clip
    }

    public static func error(_ message: String) -> NSError {
        NSError(domain: "MeetingAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
