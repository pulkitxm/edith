import Foundation

public struct VirtualCameraFrameChange: Codable, Equatable, Sendable {
    public var zoom: Double?
    public var centerX: Double?
    public var centerY: Double?
    public var tilt: Double?
    public var quarterTurns: Int?
    public var flipHorizontal: Bool?
    public var flipVertical: Bool?
    public var autoFrame: VirtualCameraAutoFrame?

    public init(
        zoom: Double? = nil, centerX: Double? = nil, centerY: Double? = nil, tilt: Double? = nil,
        quarterTurns: Int? = nil, flipHorizontal: Bool? = nil, flipVertical: Bool? = nil,
        autoFrame: VirtualCameraAutoFrame? = nil
    ) {
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
        self.tilt = tilt
        self.quarterTurns = quarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.autoFrame = autoFrame
    }

    public var isEmpty: Bool { self == VirtualCameraFrameChange() }
}

public struct VirtualCameraBackgroundChange: Codable, Equatable, Sendable {
    public var mode: VirtualCameraBackgroundMode
    public var color: VirtualCameraColor?
    public var blur: Double?
    public var imagePath: String?

    public init(
        mode: VirtualCameraBackgroundMode, color: VirtualCameraColor? = nil, blur: Double? = nil,
        imagePath: String? = nil
    ) {
        self.mode = mode
        self.color = color
        self.blur = blur
        self.imagePath = imagePath
    }
}

public enum VirtualCameraRequest: Codable, Equatable, Sendable {
    case status
    case selectSource(String)
    case zoom(Double)
    case frame(VirtualCameraFrameChange)
    case reset
    case look(VirtualCameraLookPreset)
    case background(VirtualCameraBackgroundChange)
    case pause(VirtualCameraPrivacy, message: String?)
    case resume
    case applyScene(String)
    case saveScene(String, replace: Bool)
    case stepScene(Int)

    public var changesState: Bool { self != .status }

    public var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> VirtualCameraRequest? {
        try? JSONDecoder().decode(VirtualCameraRequest.self, from: Data(text.utf8))
    }
}

public enum VirtualCameraRequestError: LocalizedError, Equatable, Sendable {
    case zoomOutOfRange(Double)
    case valueOutOfRange(String, ClosedRange<Double>)
    case emptyFrameChange
    case unknownSource(String, [String])
    case noCameras
    case notAPause
    case missingFile(String)
    case unsupportedImage(String)
    case scene(VirtualCameraSceneError)

    public var errorDescription: String? {
        switch self {
        case .zoomOutOfRange(let value):
            "Zoom must be between 1 and 8, not \(Self.format(value))."
        case .valueOutOfRange(let name, let range):
            "\(name) must be between \(Self.format(range.lowerBound)) and \(Self.format(range.upperBound))."
        case .emptyFrameChange:
            "Say what to change: --zoom, --x, --y, --tilt, --turns, --flip, --flip-vertical or --auto."
        case .unknownSource(let query, let names):
            names.isEmpty
                ? "No camera matches \(query)."
                : "No camera matches \(query). Cameras: \(names.joined(separator: ", "))."
        case .noCameras:
            "No camera is connected."
        case .notAPause:
            "Pause with card, blank or freeze. Use resume to go live."
        case .missingFile(let path):
            "Edith cannot read \(path)."
        case .unsupportedImage(let name):
            "\(name) is not an image Edith can use. Pick a PNG, JPEG, HEIC, TIFF, GIF or WebP file."
        case .scene(let error):
            error.errorDescription
        }
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

public enum VirtualCameraRequestReducer {
    @discardableResult
    public static func apply(
        _ request: VirtualCameraRequest, to state: inout VirtualCameraState,
        sources: [VirtualCameraSource],
        fileExists: (String) -> Bool = {
            FileManager.default.isReadableFile(atPath: $0)
        }
    ) throws -> String {
        switch request {
        case .status:
            return "Status"
        case .selectSource(let query):
            let source = try resolveSource(query, in: sources)
            state.sourceID = source.id
            return "Using \(source.name)."
        case .zoom(let value):
            guard value.isFinite, VirtualCameraFraming.zoomRange.contains(value) else {
                throw VirtualCameraRequestError.zoomOutOfRange(value)
            }
            state.composition.framing.zoom = value
            return "Zoom set to \(VirtualCameraRequestError.format(value))x."
        case .frame(let change):
            try applyFrame(change, to: &state.composition.framing)
            return "Framing updated."
        case .reset:
            state.composition.framing = VirtualCameraFraming()
            return "Framing reset."
        case .look(let preset):
            state.composition.look.preset = preset
            state.composition.look.intensity = 1
            return "Look set to \(preset.title)."
        case .background(let change):
            try applyBackground(change, to: &state.composition.background, fileExists: fileExists)
            return "Background set to \(change.mode.title.lowercased())."
        case .pause(let mode, let message):
            guard mode != .live else { throw VirtualCameraRequestError.notAPause }
            state.privacy = mode
            if let message, !message.trimmingCharacters(in: .whitespaces).isEmpty {
                state.privacyMessage = message
            }
            state = state.sanitized()
            return "Paused with \(mode.title.lowercased())."
        case .resume:
            state.privacy = .live
            return "Camera is live."
        case .applyScene(let query):
            let scene = try wrapScene { try VirtualCameraSceneLibrary.apply(query, in: &state) }
            return "Scene \(scene.name) applied."
        case .saveScene(let name, let replace):
            let scene = try wrapScene {
                try VirtualCameraSceneLibrary.save(name, in: &state, replacing: replace)
            }
            return "Scene \(scene.name) saved."
        case .stepScene(let offset):
            guard let scene = VirtualCameraSceneLibrary.step(offset, in: &state) else {
                throw VirtualCameraRequestError.scene(.notFound(offset >= 0 ? "next" : "previous"))
            }
            return "Scene \(scene.name) applied."
        }
    }

    public static func resolveSource(_ query: String, in sources: [VirtualCameraSource]) throws
        -> VirtualCameraSource
    {
        guard !sources.isEmpty else { throw VirtualCameraRequestError.noCameras }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = sources.first(where: { $0.id == trimmed }) { return exact }
        if let named = sources.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return named
        }
        if let number = Int(trimmed), sources.indices.contains(number - 1) {
            return sources[number - 1]
        }
        let partial = sources.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        if partial.count == 1 { return partial[0] }
        throw VirtualCameraRequestError.unknownSource(trimmed, sources.map(\.name))
    }

    static func checked(_ value: Double, _ name: String, _ range: ClosedRange<Double>) throws
        -> Double
    {
        guard value.isFinite, range.contains(value) else {
            throw VirtualCameraRequestError.valueOutOfRange(name, range)
        }
        return value
    }

    static func applyFrame(
        _ change: VirtualCameraFrameChange, to framing: inout VirtualCameraFraming
    )
        throws
    {
        guard !change.isEmpty else { throw VirtualCameraRequestError.emptyFrameChange }
        if let zoom = change.zoom {
            guard zoom.isFinite, VirtualCameraFraming.zoomRange.contains(zoom) else {
                throw VirtualCameraRequestError.zoomOutOfRange(zoom)
            }
            framing.zoom = zoom
        }
        if let x = change.centerX { framing.centerX = try checked(x, "x", 0...1) }
        if let y = change.centerY { framing.centerY = try checked(y, "y", 0...1) }
        if let tilt = change.tilt {
            framing.tilt = try checked(tilt, "tilt", VirtualCameraFraming.tiltRange)
        }
        if let turns = change.quarterTurns {
            framing.quarterTurns = Int(try checked(Double(turns), "turns", 0...3))
        }
        if let flip = change.flipHorizontal { framing.flipHorizontal = flip }
        if let flip = change.flipVertical { framing.flipVertical = flip }
        if let auto = change.autoFrame { framing.autoFrame = auto }
    }

    static func applyBackground(
        _ change: VirtualCameraBackgroundChange, to background: inout VirtualCameraBackground,
        fileExists: (String) -> Bool
    ) throws {
        if let blur = change.blur { background.blur = try checked(blur, "blur", 0...1) }
        if let color = change.color { background.color = color }
        if let path = change.imagePath {
            let expanded = (path as NSString).expandingTildeInPath
            guard fileExists(expanded) else {
                throw VirtualCameraRequestError.missingFile(expanded)
            }
            let ext = URL(fileURLWithPath: expanded).pathExtension.lowercased()
            guard VirtualCameraStore.imageExtensions.contains(ext) else {
                throw VirtualCameraRequestError.unsupportedImage(
                    URL(fileURLWithPath: expanded).lastPathComponent)
            }
            background.imagePath = expanded
        }
        if change.mode == .image, background.imagePath == nil {
            throw VirtualCameraRequestError.missingFile("a background image (pass --image)")
        }
        background.mode = change.mode
    }

    static func wrapScene(_ body: () throws -> VirtualCameraScene) throws -> VirtualCameraScene {
        do {
            return try body()
        } catch let error as VirtualCameraSceneError {
            throw VirtualCameraRequestError.scene(error)
        }
    }
}
