import CoreGraphics
import Foundation

public struct ScreenRecordingRegion: @unchecked Sendable {
    public var source: ScreenRecordingSource
    public var displayID: CGDirectDisplayID
    public var windowID: CGWindowID?
    public var sourceRect: CGRect
    public var pixelSize: CGSize
    public var anchorRect: CGRect
    public var scale: CGFloat

    public init(
        source: ScreenRecordingSource, displayID: CGDirectDisplayID,
        windowID: CGWindowID? = nil, sourceRect: CGRect, pixelSize: CGSize,
        anchorRect: CGRect, scale: CGFloat
    ) {
        self.source = source
        self.displayID = displayID
        self.windowID = windowID
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
        self.anchorRect = anchorRect
        self.scale = scale
    }
}

public enum ScreenRecordingSource: String, CaseIterable, Codable, Sendable {
    case area
    case window
    case display

    public var displayName: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .display: "Full display"
        }
    }
}

public enum ScreenRecordingFormat: String, CaseIterable, Codable, Sendable {
    case mp4
    case gif
}

public enum ScreenRecordingState: String, Codable, Sendable {
    case idle
    case selecting
    case recording
    case paused
    case finishing
    case editing
    case failed
}

public struct ScreenRecordingStatus: Codable, Equatable, Sendable {
    public var state: ScreenRecordingState
    public var source: ScreenRecordingSource?
    public var elapsedSeconds: Double
    public var takeID: UUID?
    public var message: String?

    public init(
        state: ScreenRecordingState = .idle, source: ScreenRecordingSource? = nil,
        elapsedSeconds: Double = 0, takeID: UUID? = nil, message: String? = nil
    ) {
        self.state = state
        self.source = source
        self.elapsedSeconds = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
        self.takeID = takeID
        self.message = message
    }
}

public struct ScreenRecordingRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct ScreenRecordingPoint: Codable, Equatable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double

    public init(time: Double, x: Double, y: Double) {
        self.time = time
        self.x = x
        self.y = y
    }
}

public struct ScreenRecordingClick: Codable, Equatable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double

    public init(time: Double, x: Double, y: Double) {
        self.time = time
        self.x = x
        self.y = y
    }
}

public struct ScreenRecordingPointerTrack: Codable, Equatable, Sendable {
    public var points: [ScreenRecordingPoint]
    public var clicks: [ScreenRecordingClick]

    public init(
        points: [ScreenRecordingPoint] = [], clicks: [ScreenRecordingClick] = []
    ) {
        self.points = points
        self.clicks = clicks
    }
}

public struct ScreenRecordingZoom: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var x: Double
    public var y: Double
    public var scale: Double

    public init(start: Double, end: Double, x: Double, y: Double, scale: Double = 1.8) {
        self.start = start
        self.end = end
        self.x = x
        self.y = y
        self.scale = scale
    }
}

public struct ScreenRecordingTextOverlay: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    public var x: Double
    public var y: Double
    public var fontSize: Double
    public var colorHex: String

    public init(
        id: UUID = UUID(), text: String, start: Double, end: Double,
        x: Double = 0.5, y: Double = 0.12, fontSize: Double = 34,
        colorHex: String = "#FFFFFF"
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.x = x
        self.y = y
        self.fontSize = fontSize
        self.colorHex = colorHex
    }
}

public struct ScreenRecordingExportPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var format: ScreenRecordingFormat
    public var width: Int
    public var frameRate: Int
    public var quality: Double

    public init(
        id: UUID = UUID(), name: String, format: ScreenRecordingFormat = .mp4,
        width: Int = 1920, frameRate: Int = 30, quality: Double = 0.82
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.width = width
        self.frameRate = frameRate
        self.quality = quality
    }

    public static let balanced = ScreenRecordingExportPreset(name: "Balanced")
    public static let compact = ScreenRecordingExportPreset(
        name: "Compact", width: 1280, frameRate: 24, quality: 0.68)
    public static let gif = ScreenRecordingExportPreset(
        name: "GIF", format: .gif, width: 960, frameRate: 12, quality: 0.7)
}

public enum ScreenRecordingPresetStore {
    public static func load(defaults: UserDefaults = SharedDefaults.store) -> [ScreenRecordingExportPreset] {
        guard let data = defaults.data(forKey: AppStorageKeys.Capture.recordingPresets),
            let presets = try? JSONDecoder().decode([ScreenRecordingExportPreset].self, from: data)
        else { return [.balanced, .compact, .gif] }
        return presets.isEmpty ? [.balanced, .compact, .gif] : presets
    }

    public static func save(
        _ presets: [ScreenRecordingExportPreset], defaults: UserDefaults = SharedDefaults.store
    ) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: AppStorageKeys.Capture.recordingPresets)
    }
}

public struct ScreenRecordingEditDocument: Codable, Equatable, Sendable {
    public var trimStart: Double
    public var trimEnd: Double
    public var cuts: [ScreenRecordingRange]
    public var showsPointer: Bool
    public var pointerSmoothing: Double
    public var pointerScale: Double
    public var showsClickMarkers: Bool
    public var automaticZooms: Bool
    public var zooms: [ScreenRecordingZoom]
    public var texts: [ScreenRecordingTextOverlay]
    public var crop: CGRect?
    public var backgroundHex: String?
    public var padding: Double
    public var systemAudioVolume: Double
    public var microphoneVolume: Double
    public var preset: ScreenRecordingExportPreset

    public init(
        trimStart: Double = 0, trimEnd: Double = 0,
        cuts: [ScreenRecordingRange] = [], showsPointer: Bool = true,
        pointerSmoothing: Double = 0.65, pointerScale: Double = 1,
        showsClickMarkers: Bool = true, automaticZooms: Bool = false,
        zooms: [ScreenRecordingZoom] = [], texts: [ScreenRecordingTextOverlay] = [],
        crop: CGRect? = nil, backgroundHex: String? = nil, padding: Double = 0,
        systemAudioVolume: Double = 1, microphoneVolume: Double = 1,
        preset: ScreenRecordingExportPreset = .balanced
    ) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.cuts = cuts
        self.showsPointer = showsPointer
        self.pointerSmoothing = pointerSmoothing
        self.pointerScale = pointerScale
        self.showsClickMarkers = showsClickMarkers
        self.automaticZooms = automaticZooms
        self.zooms = zooms
        self.texts = texts
        self.crop = crop
        self.backgroundHex = backgroundHex
        self.padding = padding
        self.systemAudioVolume = systemAudioVolume
        self.microphoneVolume = microphoneVolume
        self.preset = preset
    }

    public func normalized(duration: Double) -> ScreenRecordingEditDocument {
        var value = self
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        value.trimStart = min(max(0, trimStart), safeDuration)
        value.trimEnd = trimEnd > value.trimStart ? min(trimEnd, safeDuration) : safeDuration
        value.cuts = ScreenRecordingTimeline.normalized(
            cuts, duration: safeDuration, trim: value.trimStart...value.trimEnd)
        value.pointerSmoothing = min(max(pointerSmoothing, 0), 1)
        value.pointerScale = min(max(pointerScale, 0.5), 3)
        value.padding = min(max(padding, 0), 240)
        value.systemAudioVolume = min(max(systemAudioVolume, 0), 2)
        value.microphoneVolume = min(max(microphoneVolume, 0), 2)
        return value
    }

    public func keptRanges(duration: Double) -> [ScreenRecordingRange] {
        let value = normalized(duration: duration)
        return ScreenRecordingTimeline.keptRanges(
            trim: ScreenRecordingRange(start: value.trimStart, end: value.trimEnd),
            cuts: value.cuts)
    }
}

public enum ScreenRecordingTimeline {
    public static func normalized(
        _ cuts: [ScreenRecordingRange], duration: Double, trim: ClosedRange<Double>
    ) -> [ScreenRecordingRange] {
        let upper = min(max(0, duration), trim.upperBound)
        let lower = min(max(0, trim.lowerBound), upper)
        let sorted = cuts.compactMap { cut -> ScreenRecordingRange? in
            guard cut.start.isFinite, cut.end.isFinite else { return nil }
            let start = min(max(cut.start, lower), upper)
            let end = min(max(cut.end, lower), upper)
            return end - start >= 0.05 ? ScreenRecordingRange(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var merged: [ScreenRecordingRange] = []
        for cut in sorted {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1].end = max(last.end, cut.end)
            } else {
                merged.append(cut)
            }
        }
        return merged
    }

    public static func keptRanges(
        trim: ScreenRecordingRange, cuts: [ScreenRecordingRange]
    ) -> [ScreenRecordingRange] {
        var cursor = trim.start
        var ranges: [ScreenRecordingRange] = []
        for cut in cuts where cut.end > trim.start && cut.start < trim.end {
            let start = max(trim.start, cut.start)
            let end = min(trim.end, cut.end)
            if start > cursor { ranges.append(ScreenRecordingRange(start: cursor, end: start)) }
            cursor = max(cursor, end)
        }
        if cursor < trim.end { ranges.append(ScreenRecordingRange(start: cursor, end: trim.end)) }
        return ranges
    }

    public static func smoothed(
        _ points: [ScreenRecordingPoint], amount: Double
    ) -> [ScreenRecordingPoint] {
        guard points.count > 2 else { return points }
        let alpha = min(max(1 - amount, 0.05), 1)
        var forward = points
        for index in 1..<forward.count {
            forward[index].x = forward[index - 1].x + alpha * (forward[index].x - forward[index - 1].x)
            forward[index].y = forward[index - 1].y + alpha * (forward[index].y - forward[index - 1].y)
        }
        var result = forward
        for index in stride(from: result.count - 2, through: 0, by: -1) {
            result[index].x = result[index + 1].x + alpha * (result[index].x - result[index + 1].x)
            result[index].y = result[index + 1].y + alpha * (result[index].y - result[index + 1].y)
        }
        return result
    }

    public static func automaticZooms(
        clicks: [ScreenRecordingClick], duration: Double, scale: Double = 1.8
    ) -> [ScreenRecordingZoom] {
        clicks.filter { $0.time >= 0 && $0.time < max(0, duration - 0.75) }.map {
            ScreenRecordingZoom(
                start: max(0, $0.time - 0.25), end: min(duration, $0.time + 2.25),
                x: $0.x, y: $0.y, scale: min(max(scale, 1), 3))
        }
    }
}
