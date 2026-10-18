import EdithExtensionSupport
import Foundation

public enum MeetingSound: String, CaseIterable, Sendable {
    case chime, success, airhorn, applause, thunder, drumroll, rimshot, scratch, pop, countdown,
        whoosh, error

    public var name: String {
        switch self {
        case .airhorn: "Air horn"
        case .rimshot: "Rim shot"
        case .scratch: "Record scratch"
        default: rawValue.capitalized
        }
    }

    public var symbol: String {
        switch self {
        case .chime, .success: "bell"
        case .airhorn: "megaphone"
        case .applause: "hands.clap"
        case .thunder: "cloud.bolt"
        case .drumroll, .rimshot: "music.note"
        case .scratch: "opticaldisc"
        case .pop: "bubble"
        case .countdown: "timer"
        case .whoosh: "wind"
        case .error: "exclamationmark.triangle"
        }
    }

    public var identifier: String { "soundboard:\(rawValue)" }

    public var id: UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-4000-8000-%012d", Self.allCases.firstIndex(of: self)! + 1))!
    }

    public func clip() throws -> MeetingAudioClip {
        guard
            let url = BundledResources.url(
                forResource: "soundboard-\(rawValue)", withExtension: "wav")
        else {
            throw MeetingAudioLibrary.error("The \(name) sound effect is missing from the app.")
        }
        return MeetingAudioClip(id: id, name: name, path: url.path, speech: false)
    }
}
