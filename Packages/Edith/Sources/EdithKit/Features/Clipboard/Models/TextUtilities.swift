import EdithCore
import Foundation

public enum TextSnippetExpansion: String, Codable, CaseIterable, Sendable {
    case immediate
    case afterDelimiter

    public var title: String {
        switch self {
        case .immediate: "Immediately"
        case .afterDelimiter: "After space or punctuation"
        }
    }
}

public struct TextSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var trigger: String
    public var replacement: String
    public var folder: String
    public var expansion: TextSnippetExpansion
    public var ignoresCase: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(), name: String, trigger: String, replacement: String,
        folder: String = "", expansion: TextSnippetExpansion = .afterDelimiter,
        ignoresCase: Bool = false, enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.replacement = replacement
        self.folder = folder
        self.expansion = expansion
        self.ignoresCase = ignoresCase
        self.enabled = enabled
    }
}

public struct TextSnippetSection: Equatable, Identifiable, Sendable {
    public let folder: String
    public let snippets: [TextSnippet]

    public var id: String { folder }
}

public struct CleanURLResult: Equatable, Sendable {
    public let value: String
    public let removedParameters: [String]

    public init(value: String, removedParameters: [String]) {
        self.value = value
        self.removedParameters = removedParameters
    }
}

public enum TextUtilitiesSupport {
    public static let defaultAutoClearDelay = 30
    public static let bufferLimit = 128

    private static let trackingParameters: Set<String> = [
        "_hsenc", "_hsmi", "dclid", "fbclid", "gbraid", "gclid", "igshid", "li_fat_id",
        "mc_cid", "mc_eid", "mkt_tok", "msclkid", "ttclid", "twclid", "wbraid", "yclid",
    ]

    private static let hostParameters: [String: Set<String>] = [
        "bilibili.com": ["from_source", "share_source", "spm_id_from", "vd_source"],
        "instagram.com": ["igsh"],
        "reddit.com": ["$3p", "$deep_link", "_branch_match_id", "share_id"],
        "spotify.com": ["si"],
        "tiktok.com": ["_r", "_t", "share_app_name", "timestamp"],
        "twitter.com": ["ref_src", "ref_url", "s", "src", "t"],
        "x.com": ["ref_src", "ref_url", "s", "src", "t"],
        "xiaohongshu.com": ["share_id", "xsec_source", "xhsshare"],
        "youtu.be": ["feature", "pp", "si"],
        "youtube.com": ["feature", "pp", "si"],
    ]

    public static func cleanURL(
        _ text: String, customParameters: Set<String> = []
    ) -> CleanURLResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host?.lowercased()
        else { return nil }
        var names = trackingParameters.union(customParameters.map { $0.lowercased() })
        for (domain, parameters) in hostParameters
        where host == domain || host.hasSuffix("." + domain) {
            names.formUnion(parameters)
        }
        var removed: [String] = []
        components.queryItems = components.queryItems?.filter { item in
            let lowered = item.name.lowercased()
            let tracked = lowered.hasPrefix("utm_") || names.contains(lowered)
            if tracked, !removed.contains(item.name) { removed.append(item.name) }
            return !tracked
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        guard let value = components.url?.absoluteString else { return nil }
        return CleanURLResult(value: value, removedParameters: removed)
    }

    public static func customParameters(_ value: String) -> Set<String> {
        Set(
            value.split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })
    }

    public static func canRewritePasteboard(types: [String]) -> Bool {
        let allowed: Set<String> = [
            "public.utf8-plain-text", "public.url", "public.url-name", "NSStringPboardType",
            "NSURLPboardType",
        ]
        return !types.isEmpty && Set(types).isSubset(of: allowed)
    }

    public static func sanitizedTrigger(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }

    public static func sanitizedFolder(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func appending(_ buffer: String, character: String) -> String {
        String((buffer + character).suffix(bufferLimit))
    }

    public static func match(
        buffer: String, expansion: TextSnippetExpansion, snippets: [TextSnippet]
    ) -> TextSnippet? {
        let candidateBuffer =
            expansion == .afterDelimiter ? String(buffer.dropLast()) : buffer
        return snippets.filter {
            $0.enabled && $0.expansion == expansion && !$0.trigger.isEmpty
                && suffix(candidateBuffer, matches: $0.trigger, ignoresCase: $0.ignoresCase)
        }.max { $0.trigger.count < $1.trigger.count }
    }

    public static func isDelimiter(_ value: String) -> Bool {
        guard let scalar = value.unicodeScalars.first, value.unicodeScalars.count == 1 else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
    }

    public static func expand(
        _ template: String, date: Date = Date(), clipboard: String? = nil,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        var result = template.replacingOccurrences(of: "{{clipboard}}", with: clipboard ?? "")
        let formats = [
            "date": "yyyy-MM-dd", "time": "HH:mm", "datetime": "yyyy-MM-dd HH:mm",
        ]
        for (name, format) in formats {
            result = result.replacingOccurrences(
                of: "{{\(name)}}", with: formatted(date, format: format, locale: locale, timeZone: timeZone))
        }
        let expression = try? NSRegularExpression(pattern: #"\{\{(date|time):([^{}]+)\}\}"#)
        let range = NSRange(result.startIndex..., in: result)
        for match in (expression?.matches(in: result, range: range) ?? []).reversed() {
            guard let full = Range(match.range(at: 0), in: result),
                let formatRange = Range(match.range(at: 2), in: result)
            else { continue }
            let replacement = formatted(
                date, format: String(result[formatRange]), locale: locale, timeZone: timeZone)
            result.replaceSubrange(full, with: replacement)
        }
        return result
    }

    public static func sections(_ snippets: [TextSnippet], query: String = "") -> [TextSnippetSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = snippets.filter {
            needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle)
                || $0.trigger.localizedCaseInsensitiveContains(needle)
                || $0.replacement.localizedCaseInsensitiveContains(needle)
                || $0.folder.localizedCaseInsensitiveContains(needle)
        }
        let grouped = Dictionary(grouping: visible, by: \.folder)
        var result = grouped.keys.filter { !$0.isEmpty }.sorted().map {
            TextSnippetSection(folder: $0, snippets: grouped[$0] ?? [])
        }
        if let loose = grouped[""], !loose.isEmpty {
            result.append(TextSnippetSection(folder: "", snippets: loose))
        }
        return result
    }

    public static func decode(_ value: String?) -> [TextSnippet] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TextSnippet].self, from: data)) ?? []
    }

    public static func encode(_ snippets: [TextSnippet]) -> String {
        guard let data = try? JSONEncoder().encode(snippets) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func clampedAutoClearDelay(_ value: Int) -> Int {
        min(3_600, max(5, value))
    }

    public static func shouldAutoClear(
        observedChangeCount: Int?, currentChangeCount: Int, changedAt: Date?, now: Date,
        delay: TimeInterval
    ) -> Bool {
        guard let observedChangeCount, let changedAt else { return false }
        return observedChangeCount == currentChangeCount
            && now.timeIntervalSince(changedAt) >= delay
    }

    private static func suffix(_ value: String, matches trigger: String, ignoresCase: Bool) -> Bool {
        let options: String.CompareOptions = ignoresCase ? [.caseInsensitive] : []
        return value.range(of: trigger, options: options.union(.backwards))?.upperBound == value.endIndex
    }

    private static func formatted(
        _ date: Date, format: String, locale: Locale, timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = locale
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

public enum TextUtilityOperation: String, CaseIterable, Sendable {
    case cleanURL = "clean-url"
    case pastePlain = "paste-plain"
    case listSnippets = "snippets-list"
    case addSnippet = "snippets-add"
    case removeSnippet = "snippets-remove"

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "text.\(rawValue)"), summary: summary,
            cli: cli, effect: effect, requiresPreview: self == .removeSnippet)
    }

    private var cli: [String] {
        switch self {
        case .cleanURL: ["text", "clean-url"]
        case .pastePlain: ["text", "paste-plain"]
        case .listSnippets: ["text", "snippets", "ls"]
        case .addSnippet: ["text", "snippets", "add"]
        case .removeSnippet: ["text", "snippets", "rm"]
        }
    }

    private var summary: String {
        switch self {
        case .cleanURL: "Remove tracking parameters from a URL."
        case .pastePlain: "Paste the current clipboard text without formatting."
        case .listSnippets: "List saved text snippets."
        case .addSnippet: "Add a text snippet."
        case .removeSnippet: "Remove a text snippet."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .cleanURL, .listSnippets: .read
        case .pastePlain: .interactive
        case .addSnippet: .write
        case .removeSnippet: .destructive
        }
    }
}
