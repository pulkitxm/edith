import Foundation

public enum VirtualCameraAutoFrame: String, Codable, CaseIterable, Sendable {
    case off
    case close
    case medium
    case wide

    public var title: String {
        switch self {
        case .off: "Off"
        case .close: "Close"
        case .medium: "Medium"
        case .wide: "Wide"
        }
    }

    public var faceHeightFraction: Double {
        switch self {
        case .off: 0
        case .close: 0.36
        case .medium: 0.24
        case .wide: 0.15
        }
    }
}

public struct VirtualCameraFraming: Codable, Equatable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 1...8
    public static let tiltRange: ClosedRange<Double> = -45...45

    public var zoom: Double
    public var centerX: Double
    public var centerY: Double
    public var tilt: Double
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var autoFrame: VirtualCameraAutoFrame

    public init(
        zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5, tilt: Double = 0,
        quarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false,
        autoFrame: VirtualCameraAutoFrame = .off
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VirtualCameraFraming()
        self.init(
            zoom: try container.decodeIfPresent(Double.self, forKey: .zoom) ?? fallback.zoom,
            centerX: try container.decodeIfPresent(Double.self, forKey: .centerX)
                ?? fallback.centerX,
            centerY: try container.decodeIfPresent(Double.self, forKey: .centerY)
                ?? fallback.centerY,
            tilt: try container.decodeIfPresent(Double.self, forKey: .tilt) ?? fallback.tilt,
            quarterTurns: try container.decodeIfPresent(Int.self, forKey: .quarterTurns)
                ?? fallback.quarterTurns,
            flipHorizontal: try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal)
                ?? fallback.flipHorizontal,
            flipVertical: try container.decodeIfPresent(Bool.self, forKey: .flipVertical)
                ?? fallback.flipVertical,
            autoFrame: (try? container.decodeIfPresent(
                VirtualCameraAutoFrame.self, forKey: .autoFrame)) ?? fallback.autoFrame)
        self = sanitized()
    }

    public func sanitized() -> VirtualCameraFraming {
        var copy = self
        copy.zoom = VirtualCameraMath.clamp(zoom, Self.zoomRange, fallback: 1)
        copy.centerX = VirtualCameraMath.clamp(centerX, 0...1, fallback: 0.5)
        copy.centerY = VirtualCameraMath.clamp(centerY, 0...1, fallback: 0.5)
        copy.tilt = VirtualCameraMath.clamp(tilt, Self.tiltRange, fallback: 0)
        copy.quarterTurns = ((quarterTurns % 4) + 4) % 4
        return copy
    }

    public var isIdentity: Bool {
        sanitized() == VirtualCameraFraming(autoFrame: autoFrame)
    }

    public var swapsAxes: Bool { quarterTurns % 2 == 1 }
}

public enum VirtualCameraLookPreset: String, Codable, CaseIterable, Sendable {
    case natural
    case bright
    case studio
    case warm
    case cool
    case vivid
    case muted
    case film
    case mono
    case noir

    public var title: String {
        switch self {
        case .natural: "Natural"
        case .bright: "Bright"
        case .studio: "Studio"
        case .warm: "Warm"
        case .cool: "Cool"
        case .vivid: "Vivid"
        case .muted: "Muted"
        case .film: "Film"
        case .mono: "Mono"
        case .noir: "Noir"
        }
    }
}

public struct VirtualCameraLook: Codable, Equatable, Sendable {
    public var preset: VirtualCameraLookPreset
    public var intensity: Double
    public var exposure: Double
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var warmth: Double
    public var tint: Double
    public var sharpness: Double
    public var smoothing: Double
    public var vignette: Double

    public static let exposureRange: ClosedRange<Double> = -2...2
    public static let brightnessRange: ClosedRange<Double> = -0.3...0.3
    public static let contrastRange: ClosedRange<Double> = 0.5...1.5
    public static let saturationRange: ClosedRange<Double> = 0...2
    public static let signedRange: ClosedRange<Double> = -1...1
    public static let unitRange: ClosedRange<Double> = 0...1

    public init(
        preset: VirtualCameraLookPreset = .natural, intensity: Double = 1, exposure: Double = 0,
        brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, warmth: Double = 0,
        tint: Double = 0, sharpness: Double = 0, smoothing: Double = 0, vignette: Double = 0
    ) {
        self.preset = preset
        self.intensity = intensity
        self.exposure = exposure
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.tint = tint
        self.sharpness = sharpness
        self.smoothing = smoothing
        self.vignette = vignette
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VirtualCameraLook()
        func value(_ key: CodingKeys, _ defaultValue: Double) -> Double {
            (try? container.decodeIfPresent(Double.self, forKey: key)) ?? defaultValue
        }
        self.init(
            preset: (try? container.decodeIfPresent(VirtualCameraLookPreset.self, forKey: .preset))
                ?? fallback.preset,
            intensity: value(.intensity, fallback.intensity),
            exposure: value(.exposure, fallback.exposure),
            brightness: value(.brightness, fallback.brightness),
            contrast: value(.contrast, fallback.contrast),
            saturation: value(.saturation, fallback.saturation),
            warmth: value(.warmth, fallback.warmth), tint: value(.tint, fallback.tint),
            sharpness: value(.sharpness, fallback.sharpness),
            smoothing: value(.smoothing, fallback.smoothing),
            vignette: value(.vignette, fallback.vignette))
        self = sanitized()
    }

    public func sanitized() -> VirtualCameraLook {
        var copy = self
        copy.intensity = VirtualCameraMath.clamp(intensity, Self.unitRange, fallback: 1)
        copy.exposure = VirtualCameraMath.clamp(exposure, Self.exposureRange, fallback: 0)
        copy.brightness = VirtualCameraMath.clamp(brightness, Self.brightnessRange, fallback: 0)
        copy.contrast = VirtualCameraMath.clamp(contrast, Self.contrastRange, fallback: 1)
        copy.saturation = VirtualCameraMath.clamp(saturation, Self.saturationRange, fallback: 1)
        copy.warmth = VirtualCameraMath.clamp(warmth, Self.signedRange, fallback: 0)
        copy.tint = VirtualCameraMath.clamp(tint, Self.signedRange, fallback: 0)
        copy.sharpness = VirtualCameraMath.clamp(sharpness, Self.unitRange, fallback: 0)
        copy.smoothing = VirtualCameraMath.clamp(smoothing, Self.unitRange, fallback: 0)
        copy.vignette = VirtualCameraMath.clamp(vignette, Self.unitRange, fallback: 0)
        return copy
    }

    public var isNeutral: Bool {
        var neutral = VirtualCameraLook()
        neutral.intensity = intensity
        return preset == .natural && sanitized() == neutral
    }
}

public enum VirtualCameraBackgroundMode: String, Codable, CaseIterable, Sendable {
    case none
    case blur
    case color
    case image

    public var title: String {
        switch self {
        case .none: "Original"
        case .blur: "Blur"
        case .color: "Color"
        case .image: "Image"
        }
    }
}

public struct VirtualCameraBackground: Codable, Equatable, Sendable {
    public var mode: VirtualCameraBackgroundMode
    public var blur: Double
    public var color: VirtualCameraColor
    public var imagePath: String?

    public init(
        mode: VirtualCameraBackgroundMode = .none, blur: Double = 0.6,
        color: VirtualCameraColor = .slate, imagePath: String? = nil
    ) {
        self.mode = mode
        self.blur = blur
        self.color = color
        self.imagePath = imagePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VirtualCameraBackground()
        self.init(
            mode: (try? container.decodeIfPresent(VirtualCameraBackgroundMode.self, forKey: .mode))
                ?? fallback.mode,
            blur: (try? container.decodeIfPresent(Double.self, forKey: .blur)) ?? fallback.blur,
            color: (try? container.decodeIfPresent(VirtualCameraColor.self, forKey: .color))
                ?? fallback.color,
            imagePath: try? container.decodeIfPresent(String.self, forKey: .imagePath))
        self = sanitized()
    }

    public func sanitized() -> VirtualCameraBackground {
        var copy = self
        copy.blur = VirtualCameraMath.clamp(blur, 0...1, fallback: 0.6)
        if let path = imagePath, path.isEmpty { copy.imagePath = nil }
        return copy
    }

    public var needsSegmentation: Bool {
        switch mode {
        case .none: false
        case .blur: true
        case .color: true
        case .image: imagePath != nil
        }
    }
}

public enum VirtualCameraCorner: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    public var isLeading: Bool { self == .topLeft || self == .bottomLeft }
    public var isTop: Bool { self == .topLeft || self == .topRight }
}

public enum VirtualCameraNameTagStyle: String, Codable, CaseIterable, Sendable {
    case bar
    case pill
    case minimal

    public var title: String {
        switch self {
        case .bar: "Bar"
        case .pill: "Pill"
        case .minimal: "Minimal"
        }
    }
}

public struct VirtualCameraNameTag: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var title: String
    public var subtitle: String
    public var style: VirtualCameraNameTagStyle
    public var corner: VirtualCameraCorner
    public var accent: VirtualCameraColor

    public static let maximumLength = 60

    public init(
        enabled: Bool = false, title: String = "", subtitle: String = "",
        style: VirtualCameraNameTagStyle = .bar, corner: VirtualCameraCorner = .bottomLeft,
        accent: VirtualCameraColor = .accent
    ) {
        self.enabled = enabled
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.corner = corner
        self.accent = accent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VirtualCameraNameTag()
        self.init(
            enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled))
                ?? fallback.enabled,
            title: (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "",
            subtitle: (try? container.decodeIfPresent(String.self, forKey: .subtitle)) ?? "",
            style: (try? container.decodeIfPresent(VirtualCameraNameTagStyle.self, forKey: .style))
                ?? fallback.style,
            corner: (try? container.decodeIfPresent(VirtualCameraCorner.self, forKey: .corner))
                ?? fallback.corner,
            accent: (try? container.decodeIfPresent(VirtualCameraColor.self, forKey: .accent))
                ?? fallback.accent)
        self = sanitized()
    }

    public func sanitized() -> VirtualCameraNameTag {
        var copy = self
        copy.title = String(title.prefix(Self.maximumLength))
        copy.subtitle = String(subtitle.prefix(Self.maximumLength))
        return copy
    }

    public var isVisible: Bool {
        enabled
            && !(title.trimmingCharacters(in: .whitespaces).isEmpty
                && subtitle.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

public struct VirtualCameraLogo: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var imagePath: String?
    public var corner: VirtualCameraCorner
    public var size: Double
    public var opacity: Double

    public static let sizeRange: ClosedRange<Double> = 0.05...0.4

    public init(
        enabled: Bool = false, imagePath: String? = nil, corner: VirtualCameraCorner = .topRight,
        size: Double = 0.14, opacity: Double = 0.9
    ) {
        self.enabled = enabled
        self.imagePath = imagePath
        self.corner = corner
        self.size = size
        self.opacity = opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VirtualCameraLogo()
        self.init(
            enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled))
                ?? fallback.enabled,
            imagePath: try? container.decodeIfPresent(String.self, forKey: .imagePath),
            corner: (try? container.decodeIfPresent(VirtualCameraCorner.self, forKey: .corner))
                ?? fallback.corner,
            size: (try? container.decodeIfPresent(Double.self, forKey: .size)) ?? fallback.size,
            opacity: (try? container.decodeIfPresent(Double.self, forKey: .opacity))
                ?? fallback.opacity)
        self = sanitized()
    }

    public func sanitized() -> VirtualCameraLogo {
        var copy = self
        copy.size = VirtualCameraMath.clamp(size, Self.sizeRange, fallback: 0.14)
        copy.opacity = VirtualCameraMath.clamp(opacity, 0...1, fallback: 0.9)
        if let path = imagePath, path.isEmpty { copy.imagePath = nil }
        return copy
    }

    public var isVisible: Bool { enabled && imagePath != nil && opacity > 0 }
}

public struct VirtualCameraClock: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var corner: VirtualCameraCorner
    public var showsSeconds: Bool
    public var twentyFourHour: Bool

    public init(
        enabled: Bool = false, corner: VirtualCameraCorner = .topLeft, showsSeconds: Bool = false,
        twentyFourHour: Bool = false
    ) {
        self.enabled = enabled
        self.corner = corner
        self.showsSeconds = showsSeconds
        self.twentyFourHour = twentyFourHour
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false,
            corner: (try? container.decodeIfPresent(VirtualCameraCorner.self, forKey: .corner))
                ?? .topLeft,
            showsSeconds: (try? container.decodeIfPresent(Bool.self, forKey: .showsSeconds))
                ?? false,
            twentyFourHour: (try? container.decodeIfPresent(Bool.self, forKey: .twentyFourHour))
                ?? false)
    }

    public func text(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = parts.second ?? 0
        let seconds = showsSeconds ? String(format: ":%02d", second) : ""
        if twentyFourHour {
            return String(format: "%02d:%02d", hour, minute) + seconds
        }
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", displayHour, minute) + seconds
            + (hour < 12 ? " AM" : " PM")
    }
}

public struct VirtualCameraBorder: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var width: Double
    public var cornerRadius: Double
    public var inset: Double
    public var color: VirtualCameraColor
    public var matte: VirtualCameraColor

    public static let widthRange: ClosedRange<Double> = 0...0.05
    public static let cornerRange: ClosedRange<Double> = 0...0.5
    public static let insetRange: ClosedRange<Double> = 0...0.2

    public init(
        enabled: Bool = false, width: Double = 0.01, cornerRadius: Double = 0.05,
        inset: Double = 0.04, color: VirtualCameraColor = .white,
        matte: VirtualCameraColor = .matte
    ) {
        self.enabled = enabled
        self.width = width
        self.cornerRadius = cornerRadius
        self.inset = inset
        self.color = color
        self.matte = matte
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VirtualCameraBorder()
        func value(_ key: CodingKeys, _ defaultValue: Double) -> Double {
            (try? container.decodeIfPresent(Double.self, forKey: key)) ?? defaultValue
        }
        self.init(
            enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false,
            width: value(.width, fallback.width),
            cornerRadius: value(.cornerRadius, fallback.cornerRadius),
            inset: value(.inset, fallback.inset),
            color: (try? container.decodeIfPresent(VirtualCameraColor.self, forKey: .color))
                ?? fallback.color,
            matte: (try? container.decodeIfPresent(VirtualCameraColor.self, forKey: .matte))
                ?? fallback.matte)
        self = sanitized()
    }

    public func sanitized() -> VirtualCameraBorder {
        var copy = self
        copy.width = VirtualCameraMath.clamp(width, Self.widthRange, fallback: 0.01)
        copy.cornerRadius = VirtualCameraMath.clamp(cornerRadius, Self.cornerRange, fallback: 0)
        copy.inset = VirtualCameraMath.clamp(inset, Self.insetRange, fallback: 0)
        return copy
    }
}

public struct VirtualCameraOverlays: Codable, Equatable, Sendable {
    public var nameTag: VirtualCameraNameTag
    public var logo: VirtualCameraLogo
    public var clock: VirtualCameraClock
    public var border: VirtualCameraBorder

    public init(
        nameTag: VirtualCameraNameTag = VirtualCameraNameTag(),
        logo: VirtualCameraLogo = VirtualCameraLogo(),
        clock: VirtualCameraClock = VirtualCameraClock(),
        border: VirtualCameraBorder = VirtualCameraBorder()
    ) {
        self.nameTag = nameTag
        self.logo = logo
        self.clock = clock
        self.border = border
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            nameTag: (try? container.decodeIfPresent(VirtualCameraNameTag.self, forKey: .nameTag))
                ?? VirtualCameraNameTag(),
            logo: (try? container.decodeIfPresent(VirtualCameraLogo.self, forKey: .logo))
                ?? VirtualCameraLogo(),
            clock: (try? container.decodeIfPresent(VirtualCameraClock.self, forKey: .clock))
                ?? VirtualCameraClock(),
            border: (try? container.decodeIfPresent(VirtualCameraBorder.self, forKey: .border))
                ?? VirtualCameraBorder())
    }

    public var activeCount: Int {
        [nameTag.isVisible, logo.isVisible, clock.enabled, border.enabled].filter { $0 }.count
    }
}

public struct VirtualCameraComposition: Codable, Equatable, Sendable {
    public var framing: VirtualCameraFraming
    public var look: VirtualCameraLook
    public var background: VirtualCameraBackground
    public var overlays: VirtualCameraOverlays

    public init(
        framing: VirtualCameraFraming = VirtualCameraFraming(),
        look: VirtualCameraLook = VirtualCameraLook(),
        background: VirtualCameraBackground = VirtualCameraBackground(),
        overlays: VirtualCameraOverlays = VirtualCameraOverlays()
    ) {
        self.framing = framing
        self.look = look
        self.background = background
        self.overlays = overlays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            framing: (try? container.decodeIfPresent(VirtualCameraFraming.self, forKey: .framing))
                ?? VirtualCameraFraming(),
            look: (try? container.decodeIfPresent(VirtualCameraLook.self, forKey: .look))
                ?? VirtualCameraLook(),
            background: (try? container.decodeIfPresent(
                VirtualCameraBackground.self, forKey: .background)) ?? VirtualCameraBackground(),
            overlays: (try? container.decodeIfPresent(
                VirtualCameraOverlays.self, forKey: .overlays)) ?? VirtualCameraOverlays())
    }

    public func sanitized() -> VirtualCameraComposition {
        VirtualCameraComposition(
            framing: framing.sanitized(), look: look.sanitized(),
            background: background.sanitized(),
            overlays: VirtualCameraOverlays(
                nameTag: overlays.nameTag.sanitized(), logo: overlays.logo.sanitized(),
                clock: overlays.clock, border: overlays.border.sanitized()))
    }
}

public enum VirtualCameraMath {
    public static func clamp(
        _ value: Double, _ range: ClosedRange<Double>, fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    public static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }

    public static func easeInOut(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
