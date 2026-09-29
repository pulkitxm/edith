import Foundation

struct VideoMarkerFrameRate: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int

    static let fps30 = VideoMarkerFrameRate(uncheckedNumerator: 30, denominator: 1)

    init(numerator: Int, denominator: Int = 1) throws {
        guard numerator > 0, numerator <= Int32.max,
            denominator > 0, denominator <= Int32.max,
            Double(numerator) / Double(denominator) >= 1,
            Double(numerator) / Double(denominator) <= 240
        else { throw VideoMarkerError.invalidFrameRate }
        var a = numerator
        var b = denominator
        while b != 0 { (a, b) = (b, a % b) }
        self.numerator = numerator / a
        self.denominator = denominator / a
    }

    private init(uncheckedNumerator: Int, denominator: Int) {
        self.numerator = uncheckedNumerator
        self.denominator = denominator
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            numerator: values.decode(Int.self, forKey: .numerator),
            denominator: values.decode(Int.self, forKey: .denominator))
    }

    var framesPerSecond: Double { Double(numerator) / Double(denominator) }
    var label: String {
        denominator == 1 ? "\(numerator) fps" : "\(numerator)/\(denominator) fps NDF"
    }

    func frame(at seconds: Double) throws -> Int64 {
        let value = (seconds * framesPerSecond).rounded()
        guard seconds.isFinite, seconds >= 0, value <= Double(VideoMarker.maximumFrame) else {
            throw VideoMarkerError.invalidFrame
        }
        return Int64(value)
    }

    func seconds(at frame: Int64) -> Double {
        Double(frame) * Double(denominator) / Double(numerator)
    }

    func timecode(at frame: Int64) -> String {
        let nominal = Int64(ceil(framesPerSecond))
        let value = max(0, frame)
        let seconds = value / nominal
        return String(
            format: "%02lld:%02lld:%02lld:%02lld", seconds / 3600,
            seconds / 60 % 60, seconds % 60, value % nominal)
    }
}

struct VideoMarker: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case manual
        case transient
    }

    static let maximumFrame: Int64 = 1_000_000_000_000
    let id: String
    var frame: Int64
    var frameRate: VideoMarkerFrameRate
    var label: String
    var kind: Kind

    init(
        id: String = "marker_\(UUID().uuidString.lowercased())",
        frame: Int64, frameRate: VideoMarkerFrameRate = .fps30,
        label: String = "Marker", kind: Kind = .manual
    ) throws {
        self.id = id
        self.frame = frame
        self.frameRate = frameRate
        self.label = label
        self.kind = kind
        try validate()
    }

    var seconds: Double { frameRate.seconds(at: frame) }
    var timecode: String { "\(frameRate.timecode(at: frame)) (\(frameRate.label))" }

    func validate() throws {
        guard frame >= 0, frame <= Self.maximumFrame else { throw VideoMarkerError.invalidFrame }
        guard !id.isEmpty, id.utf8.count <= 200, label.utf8.count <= 4096 else {
            throw VideoMarkerError.invalidMarker
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            frame: values.decode(Int64.self, forKey: .frame),
            frameRate: values.decode(VideoMarkerFrameRate.self, forKey: .frameRate),
            label: values.decode(String.self, forKey: .label),
            kind: values.decode(Kind.self, forKey: .kind))
    }
}

enum VideoMarkerError: LocalizedError {
    case invalidFrameRate, invalidFrame, invalidMarker, duplicateID, missingMarker, invalidDocument

    var errorDescription: String? {
        switch self {
        case .invalidFrameRate: return "Use a positive rational frame rate between 1 and 240 fps."
        case .invalidFrame:
            return "Marker frames must be nonnegative and within the supported range."
        case .invalidMarker: return "Marker IDs and labels must be valid and within size limits."
        case .duplicateID: return "Marker IDs must be unique."
        case .missingMarker: return "The selected marker no longer exists."
        case .invalidDocument: return "The marker document is invalid or exceeds the size limit."
        }
    }
}

enum VideoMarkers {
    static let maximumCount = 100_000

    private struct Document: Codable {
        let version: Int
        let markers: [VideoMarker]
    }

    static func validate(_ markers: [VideoMarker]) throws {
        guard markers.count <= maximumCount else { throw VideoMarkerError.invalidDocument }
        var ids = Set<String>()
        for marker in markers {
            try marker.validate()
            guard ids.insert(marker.id).inserted else { throw VideoMarkerError.duplicateID }
        }
    }

    static func export(_ markers: [VideoMarker]) throws -> Data {
        try validate(markers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, markers: sorted(markers)))
        guard data.count <= 32 * 1024 * 1024 else { throw VideoMarkerError.invalidDocument }
        return data
    }

    static func parse(_ data: Data) throws -> [VideoMarker] {
        guard data.count <= 32 * 1024 * 1024 else { throw VideoMarkerError.invalidDocument }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw VideoMarkerError.invalidDocument }
        try validate(document.markers)
        return sorted(document.markers)
    }

    static func sorted(_ markers: [VideoMarker]) -> [VideoMarker] {
        markers.sorted {
            if $0.seconds != $1.seconds { return $0.seconds < $1.seconds }
            return $0.id < $1.id
        }
    }

    static func nearestFrame(
        to frame: Int64, markers: [VideoMarker], thresholdFrames: Int64,
        frameRate: VideoMarkerFrameRate = .fps30
    ) -> Int64? {
        guard frame >= 0, frame <= VideoMarker.maximumFrame, thresholdFrames >= 0 else {
            return nil
        }
        var nearest: Int64?
        var distance = Int64.max
        for marker in markers {
            guard let candidate = try? frameRate.frame(at: marker.seconds) else { continue }
            let delta = abs(candidate - frame)
            if delta <= thresholdFrames,
                delta < distance || (delta == distance && candidate < (nearest ?? Int64.max))
            {
                nearest = candidate
                distance = delta
            }
        }
        return nearest
    }
}

extension VideoProject {
    var markers: [VideoMarker] {
        guard let entries = root["edithMarkers"] as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: entries),
            let decoded = try? JSONDecoder().decode([VideoMarker].self, from: data),
            (try? VideoMarkers.validate(decoded)) != nil
        else { return [] }
        return VideoMarkers.sorted(decoded)
    }

    mutating func setMarkers(_ markers: [VideoMarker]) throws {
        try VideoMarkers.validate(markers)
        root["edithMarkers"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(VideoMarkers.sorted(markers)))
    }

    @discardableResult
    mutating func addMarker(
        atFrame frame: Int64, frameRate: VideoMarkerFrameRate = .fps30,
        label: String = "Marker", kind: VideoMarker.Kind = .manual
    ) throws -> VideoMarker {
        let marker = try VideoMarker(frame: frame, frameRate: frameRate, label: label, kind: kind)
        try setMarkers(markers + [marker])
        return marker
    }

    mutating func updateMarker(
        _ id: String, frame: Int64? = nil, frameRate: VideoMarkerFrameRate? = nil,
        label: String? = nil, kind: VideoMarker.Kind? = nil
    ) throws {
        var entries = markers
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw VideoMarkerError.missingMarker
        }
        if let frameRate {
            entries[index].frame = try frameRate.frame(at: entries[index].seconds)
            entries[index].frameRate = frameRate
        }
        if let frame { entries[index].frame = frame }
        if let label { entries[index].label = label }
        if let kind { entries[index].kind = kind }
        try setMarkers(entries)
    }

    mutating func removeMarker(_ id: String) throws {
        guard markers.contains(where: { $0.id == id }) else { throw VideoMarkerError.missingMarker }
        try setMarkers(markers.filter { $0.id != id })
    }

    mutating func importMarkers(_ data: Data, replace: Bool = false) throws {
        let imported = try VideoMarkers.parse(data)
        try setMarkers((replace ? [] : markers) + imported)
    }

    func exportMarkers() throws -> Data { try VideoMarkers.export(markers) }

    func exportMarkers(to destination: URL) throws {
        try VideoProjectExportDestination.validate(destination, project: self)
        try exportMarkers().write(to: destination, options: .atomic)
    }

    func snapToMarker(
        frame: Int64, thresholdFrames: Int64 = 3,
        frameRate: VideoMarkerFrameRate = .fps30
    ) -> Int64 {
        VideoMarkers.nearestFrame(
            to: frame, markers: markers, thresholdFrames: thresholdFrames,
            frameRate: frameRate) ?? frame
    }
}
