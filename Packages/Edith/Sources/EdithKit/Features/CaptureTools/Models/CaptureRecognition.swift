import CoreGraphics
import Foundation
import Vision

public enum CaptureCopyMode: String, CaseIterable, Codable, Sendable {
    case smart
    case text
    case codes
    case combined

    public var displayName: String {
        switch self {
        case .smart: "Best result"
        case .text: "Text only"
        case .codes: "Codes only"
        case .combined: "Text and codes"
        }
    }
}

public struct CaptureCode: Codable, Equatable, Hashable, Sendable {
    public let symbology: String
    public let payload: String

    public init(symbology: String, payload: String) {
        self.symbology = symbology
        self.payload = payload
    }
}

public struct CaptureRecognition: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let text: String
    public let codes: [CaptureCode]
    public let imagePath: String?

    public init(
        id: UUID = UUID(), capturedAt: Date = Date(), text: String,
        codes: [CaptureCode], imagePath: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.codes = codes
        self.imagePath = imagePath
    }

    public var isEmpty: Bool { text.isEmpty && codes.isEmpty }

    public func output(for mode: CaptureCopyMode) -> String {
        let payloads = codes.map(\.payload).uniqued()
        switch mode {
        case .smart:
            return payloads.isEmpty ? text : payloads.joined(separator: "\n")
        case .text:
            return text
        case .codes:
            return payloads.joined(separator: "\n")
        case .combined:
            return joined(text: text, payloads: payloads)
        }
    }

    private func joined(text: String, payloads: [String]) -> String {
        ([text].filter { !$0.isEmpty } + payloads).uniqued().joined(separator: "\n")
    }
}

public enum CaptureRecognitionError: LocalizedError, Equatable {
    case unreadableImage

    public var errorDescription: String? {
        "The captured image could not be read."
    }
}

public enum CaptureRecognizedLink {
    public static func openable(_ value: String) -> URL? {
        guard !value.contains(where: { $0.isWhitespace }),
            let components = URLComponents(string: value),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.isEmpty == false, components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }
}

public enum CaptureRecognizer {
    public static func recognize(
        _ image: CGImage, detectCodes: Bool = true
    ) throws -> CaptureRecognition {
        let accurateRequest = textRequest(level: .accurate, detectsLanguage: true)
        let codeRequest = VNDetectBarcodesRequest()
        codeRequest.symbologies = [.qr, .microQR, .aztec, .dataMatrix, .pdf417]
        let requests: [VNRequest] =
            detectCodes ? [codeRequest, accurateRequest] : [accurateRequest]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)

        var lines = sortedText(accurateRequest.results ?? [])
        if lines.isEmpty {
            let fallback = textRequest(level: .fast, detectsLanguage: false)
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([fallback])
            lines = sortedText(fallback.results ?? [])
        }

        let codes = (codeRequest.results ?? [])
            .sorted { positioned($0.boundingBox, before: $1.boundingBox) }
            .compactMap { observation -> CaptureCode? in
                guard
                    let payload = observation.payloadStringValue?.trimmingCharacters(
                        in: .whitespacesAndNewlines), !payload.isEmpty
                else { return nil }
                return CaptureCode(symbology: observation.symbology.rawValue, payload: payload)
            }.uniqued()

        return CaptureRecognition(text: lines.joined(separator: "\n"), codes: codes)
    }

    private static func textRequest(
        level: VNRequestTextRecognitionLevel, detectsLanguage: Bool
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        request.automaticallyDetectsLanguage = detectsLanguage
        return request
    }

    private static func sortedText(
        _ observations: [VNRecognizedTextObservation]
    ) -> [String] {
        observations.compactMap { observation -> (String, CGRect)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
        .sorted { positioned($0.1, before: $1.1) }
        .map(\.0)
    }

    private static func positioned(_ lhs: CGRect, before rhs: CGRect) -> Bool {
        let rowDistance = abs(lhs.midY - rhs.midY)
        return rowDistance > 0.02 ? lhs.midY > rhs.midY : lhs.minX < rhs.minX
    }
}

public enum CaptureHistoryStore {
    public static func load(
        from defaults: UserDefaults = SharedDefaults.store
    ) -> [CaptureRecognition] {
        guard let data = defaults.data(forKey: AppStorageKeys.Capture.history),
            let captures = try? JSONDecoder().decode([CaptureRecognition].self, from: data)
        else { return [] }
        return captures
    }

    public static func add(
        _ capture: CaptureRecognition, limit: Int,
        into defaults: UserDefaults = SharedDefaults.store
    ) {
        let captures = Array(([capture] + load(from: defaults)).prefix(max(1, limit)))
        guard let data = try? JSONEncoder().encode(captures) else { return }
        defaults.set(data, forKey: AppStorageKeys.Capture.history)
    }

    public static func clear(in defaults: UserDefaults = SharedDefaults.store) {
        defaults.removeObject(forKey: AppStorageKeys.Capture.history)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
