import Foundation

public enum ScratchpadRetention: String, CaseIterable, Codable, Sendable {
    case never
    case hour
    case day
    case week
    case month

    public var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        }
    }

    public var title: String {
        switch self {
        case .never: "Never"
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "1 week"
        case .month: "30 days"
        }
    }

    public static func resolved(_ rawValue: String?) -> ScratchpadRetention {
        rawValue.flatMap(ScratchpadRetention.init(rawValue:)) ?? .never
    }
}

public struct ScratchpadPad: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var text: String
    public let createdAt: Date
    public var modifiedAt: Date?

    public init(
        id: UUID = UUID(), name: String, text: String = "", createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public struct ScratchpadDocument: Codable, Equatable, Sendable {
    public static let maximumPadCount = 24
    public static let maximumNameLength = 48

    public var pads: [ScratchpadPad]
    public var selectedID: UUID

    public init(pads: [ScratchpadPad], selectedID: UUID) {
        self.pads = pads
        self.selectedID = selectedID
    }

    public static func initial(now: Date = Date(), id: UUID = UUID()) -> ScratchpadDocument {
        let pad = ScratchpadPad(id: id, name: "Scratchpad 1", createdAt: now)
        return ScratchpadDocument(pads: [pad], selectedID: id)
    }

    public var selectedPad: ScratchpadPad? {
        pads.first { $0.id == selectedID }
    }

    public func sanitized(now: Date = Date()) -> ScratchpadDocument {
        var seen = Set<UUID>()
        var cleaned: [ScratchpadPad] = []
        for pad in pads.prefix(Self.maximumPadCount) where seen.insert(pad.id).inserted {
            let proposed = ScratchpadNaming.sanitized(pad.name)
            let name = ScratchpadNaming.unique(
                proposed.isEmpty ? "Scratchpad" : proposed,
                excluding: nil, in: cleaned)
            cleaned.append(
                ScratchpadPad(
                    id: pad.id, name: name, text: pad.text, createdAt: pad.createdAt,
                    modifiedAt: pad.text.isEmpty ? nil : pad.modifiedAt))
        }
        guard !cleaned.isEmpty else { return .initial(now: now) }
        let selection = cleaned.contains { $0.id == selectedID } ? selectedID : cleaned[0].id
        return ScratchpadDocument(pads: cleaned, selectedID: selection)
    }

    @discardableResult
    public mutating func applyRetention(_ retention: ScratchpadRetention, now: Date) -> Int {
        guard let interval = retention.interval else { return 0 }
        var cleared = 0
        for index in pads.indices {
            guard !pads[index].text.isEmpty, let modifiedAt = pads[index].modifiedAt,
                now.timeIntervalSince(modifiedAt) > interval
            else { continue }
            pads[index].text = ""
            pads[index].modifiedAt = nil
            cleared += 1
        }
        return cleared
    }

    public func nextExpiry(for retention: ScratchpadRetention) -> Date? {
        guard let interval = retention.interval else { return nil }
        return pads.compactMap { pad in
            guard !pad.text.isEmpty, let modifiedAt = pad.modifiedAt else { return nil }
            return modifiedAt.addingTimeInterval(interval)
        }.min()
    }
}

public enum ScratchpadNaming {
    public static func sanitized(_ name: String) -> String {
        let words = name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(ScratchpadDocument.maximumNameLength))
    }

    public static func unique(
        _ proposed: String, excluding id: UUID?, in pads: [ScratchpadPad]
    ) -> String {
        let base = sanitized(proposed).isEmpty ? "Scratchpad" : sanitized(proposed)
        let names = Set(pads.filter { $0.id != id }.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var suffix = 2
        while true {
            let suffixText = " \(suffix)"
            let baseLimit = ScratchpadDocument.maximumNameLength - suffixText.count
            let candidate = String(base.prefix(baseLimit)) + suffixText
            if !names.contains(candidate.lowercased()) { return candidate }
            suffix += 1
        }
    }

    public static func next(in pads: [ScratchpadPad]) -> String {
        unique("Scratchpad \(pads.count + 1)", excluding: nil, in: pads)
    }
}

public struct ScratchpadSearchResult: Equatable, Sendable {
    public let pad: ScratchpadPad
    public let matchCount: Int

    public init(pad: ScratchpadPad, matchCount: Int) {
        self.pad = pad
        self.matchCount = matchCount
    }
}

public enum ScratchpadError: LocalizedError, Equatable {
    case padLimit
    case padNotFound(String)
    case invalidName
    case onlyPad
    case emptyPad

    public var errorDescription: String? {
        switch self {
        case .padLimit: "Scratchpad can keep up to \(ScratchpadDocument.maximumPadCount) pads."
        case .padNotFound(let selector): "No scratchpad matches \"\(selector)\"."
        case .invalidName: "A scratchpad name cannot be empty."
        case .onlyPad: "The last scratchpad cannot be removed."
        case .emptyPad: "The scratchpad is empty."
        }
    }
}
