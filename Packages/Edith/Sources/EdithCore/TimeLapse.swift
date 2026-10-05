import Foundation

public struct TimeLapseSettings: Codable, Equatable, Sendable {
    public static let playbackFPS: Int32 = 30
    public static let framesPerSegment = 300
    public static let diskReserve: Int64 = 512 * 1024 * 1024
    public static let intervals: [Double] = [1, 2, 5, 10, 30, 60]
    public static var speeds: [Double] { intervals.map { $0 * Double(playbackFPS) } }

    public var interval: Double = 5
    public var maximumDimension = 3840
    public var systemAudio = false
    public var microphoneID: String?
    public var showCursor = true
    public var keepAwake = true

    public init() {}

    public func validate() throws {
        guard Self.intervals.contains(interval), [1920, 3840, 7680].contains(maximumDimension)
        else { throw TimeLapseError.invalidSettings }
    }

    public var segmentFrameLimit: Int { min(Self.framesPerSegment, max(1, Int(300 / interval))) }

    public var speed: Double {
        get { interval * Double(Self.playbackFPS) }
        set { interval = newValue / Double(Self.playbackFPS) }
    }
    public var videoBitRate: Int {
        maximumDimension <= 1920 ? 6_000_000 : (maximumDimension <= 3840 ? 12_000_000 : 48_000_000)
    }
    public var audioBitRate: Int {
        (systemAudio ? 128_000 : 0) + (microphoneID == nil ? 0 : 128_000)
    }

    public func estimatedBytes(hours: Double) -> Double {
        hours * 3600 * (Double(videoBitRate) / speed + Double(audioBitRate)) / 8
    }

    public func dimensions(width: Double, height: Double) -> (width: Int, height: Int) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return (2, 2) }
        let scale = min(1, Double(maximumDimension) / max(width, height))
        return (max(2, Int(width * scale) / 2 * 2), max(2, Int(height * scale) / 2 * 2))
    }
}

public struct TimeLapseClock: Sendable {
    public private(set) var frames: Int64 = 0
    private var lastCapture: Double?
    public let interval: Double

    public init(interval: Double) { self.interval = interval }

    public func isDue(at uptime: Double) -> Bool {
        guard uptime.isFinite, interval.isFinite, interval > 0 else { return false }
        guard let lastCapture else { return true }
        return uptime - lastCapture >= interval - 0.001
    }

    public mutating func accepted(at uptime: Double) {
        lastCapture = uptime
        frames += 1
    }

    public var playbackSeconds: Double { Double(frames) / Double(TimeLapseSettings.playbackFPS) }
}

public enum TimeLapseError: LocalizedError {
    case invalidSettings
    case missingSource
    case diskFull
    case encoding(String)
    case empty
    case invalidSession

    public var errorDescription: String? {
        switch self {
        case .invalidSettings: "Choose a supported capture interval and resolution."
        case .missingSource: "The selected display or windows are unavailable. Refresh sources."
        case .diskFull: "Recording stopped to leave 512 MB free on the recording drive."
        case .encoding(let message): message
        case .empty: "No frames were captured. Check Screen Recording permission and the source."
        case .invalidSession: "This recording session contains invalid media references."
        }
    }
}

public struct TimeLapseSession: Codable, Identifiable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public let file: String
        public let kind: String
        public let frames: Int
        public let startedAt: Date
        public let duration: Double

        public init(file: String, kind: String, frames: Int, startedAt: Date, duration: Double) {
            self.file = file
            self.kind = kind
            self.frames = frames
            self.startedAt = startedAt
            self.duration = duration
        }
    }

    public let id: UUID
    public let startedAt: Date
    public let settings: TimeLapseSettings
    public let width: Int
    public let height: Int
    public var segments: [Segment] = []
    public var endedAt: Date?
    public var failure: String?

    public init(settings: TimeLapseSettings, width: Int, height: Int) {
        id = UUID()
        startedAt = Date()
        self.settings = settings
        self.width = width
        self.height = height
    }

    public var frames: Int { segments.filter { $0.kind == "video" }.reduce(0) { $0 + $1.frames } }
    public var playbackSeconds: Double { Double(frames) / Double(TimeLapseSettings.playbackFPS) }

    public func validate() throws {
        try settings.validate()
        guard width >= 2, height >= 2, width <= 7680, height <= 7680,
            width % 2 == 0, height % 2 == 0,
            Set(segments.map(\.file)).count == segments.count,
            segments.allSatisfy({
                !$0.file.isEmpty && !$0.file.contains("/") && !$0.file.contains("\\")
                    && !$0.file.hasPrefix(".")
                    && ["video", "system", "microphone"].contains($0.kind)
                    && $0.duration.isFinite && $0.duration > 0 && $0.frames >= 0
                    && ($0.kind != "video" || $0.frames > 0)
            })
        else { throw TimeLapseError.invalidSession }
    }
}
