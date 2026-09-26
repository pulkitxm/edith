import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(Translation)
import Translation
#endif

enum StudioSummarizer {
    static let chunkLimit = 6000

    static func summarize(
        _ text: String, length: String, bullets: Bool, progress: @escaping (Double) -> Void
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard StudioIntelligence.isModelAvailable else { throw unavailable }
            var pieces = chunks(text, limit: chunkLimit)
            var round = 0
            while pieces.count > 1 && round < 4 {
                var partials: [String] = []
                for (index, piece) in pieces.enumerated() {
                    try Task.checkCancellation()
                    partials.append(
                        try await respond(
                            "Summarize the key facts in this part of a longer document as concise bullet points:",
                            text: piece))
                    progress(Double(index + 1) / Double(pieces.count) * 0.8)
                }
                pieces = chunks(partials.joined(separator: "\n"), limit: chunkLimit)
                round += 1
            }
            let final = try await respond(
                instruction(length: length, bullets: bullets), text: pieces.first ?? text)
            progress(1)
            return final.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw unavailable
    }

    static var unavailable: StudioError {
        StudioError.unavailable(
            "Summaries need Apple Intelligence. Turn it on in System Settings > Apple Intelligence & Siri."
        )
    }

    static func instruction(length: String, bullets: Bool) -> String {
        let size: String
        switch length {
        case "short":
            size = bullets ? "3 to 5 bullet points" : "one short paragraph of about 80 words"
        case "detailed":
            size =
                bullets
                ? "a detailed outline with short section headings and bullet points"
                : "several paragraphs of about 400 words in total"
        default: size = bullets ? "6 to 10 bullet points" : "two paragraphs of about 180 words"
        }
        return "Summarize the following document as \(size). Use Markdown. "
            + "Only include facts that appear in the text."
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func respond(_ instruction: String, text: String) async throws -> String {
        let session = LanguageModelSession(
            instructions:
                "You summarize documents accurately and neutrally. Write in the same language as the document."
        )
        do {
            return try await session.respond(to: instruction + "\n\n" + text).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                let halves = chunks(text, limit: max(800, text.count / 2))
                var parts: [String] = []
                for half in halves where halves.count > 1 {
                    parts.append(try await respond(instruction, text: half))
                }
                guard !parts.isEmpty else {
                    throw StudioError.failed("The document is too long to summarize.")
                }
                return parts.joined(separator: "\n")
            case .guardrailViolation:
                throw StudioError.failed(
                    "Apple Intelligence declined to summarize this document because of its content."
                )
            default:
                throw StudioError.failed(
                    "Apple Intelligence could not summarize: \(error.localizedDescription)")
            }
        }
    }
    #endif

    static func chunks(_ text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            var remaining = paragraph
            if remaining.count > limit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            while remaining.count > limit {
                result.append(String(remaining.prefix(limit)))
                remaining = String(remaining.dropFirst(limit))
            }
            if current.count + remaining.count + 1 > limit, !current.isEmpty {
                result.append(current)
                current = remaining
            } else {
                current = current.isEmpty ? remaining : current + "\n" + remaining
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result
    }
}

enum StudioTranslator {
    static func normalized(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).minimalIdentifier
    }

    static func detectLanguage(_ text: String) throws -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(6000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else {
            throw StudioError.invalidOption("from", "the language could not be detected, choose it")
        }
        return language.rawValue
    }

    static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func translateStrings(
        _ strings: [String], from source: String, to target: String,
        progress: @escaping (Double) -> Void
    ) async throws -> [String] {
        let blocks = strings.map {
            DocumentMarkdown.Block(
                text: $0, markdown: $0, heading: nil, listLevel: 0, ordered: false)
        }
        let translated = try await translate(blocks, from: source, to: target, progress: progress)
        return translated.map(\.text)
    }

    static func translate(
        _ blocks: [DocumentMarkdown.Block], from source: String, to target: String,
        progress: @escaping (Double) -> Void
    ) async throws -> [DocumentMarkdown.Block] {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let from = Locale.Language(identifier: source)
            let to = Locale.Language(identifier: target)
            switch await LanguageAvailability().status(from: from, to: to) {
            case .installed:
                break
            case .supported:
                throw StudioError.unavailable(
                    "Download \(name(source)) and \(name(target)) in System Settings > General > Language & Region > Translation Languages, then try again."
                )
            case .unsupported:
                throw StudioError.unavailable(
                    "This Mac cannot translate from \(name(source)) to \(name(target)).")
            @unknown default:
                throw StudioError.unavailable("Translation is not available right now.")
            }
            let session = TranslationSession(installedSource: from, target: to)
            var segments: [String] = []
            var owners: [(block: Int, row: Int?, cell: Int?)] = []
            for (index, block) in blocks.enumerated() {
                if block.markdown.hasPrefix("|") {
                    for (row, line) in block.markdown.split(separator: "\n").enumerated() {
                        let text = String(line)
                        if text.replacingOccurrences(of: " ", with: "").hasPrefix("|---") {
                            continue
                        }
                        for (cell, value) in IntelligenceSource.tableCells(text).enumerated()
                        where !value.isEmpty {
                            segments.append(value)
                            owners.append((index, row, cell))
                        }
                    }
                } else {
                    segments.append(block.text)
                    owners.append((index, nil, nil))
                }
            }
            var translated = Array(repeating: "", count: segments.count)
            let batch = 40
            var start = 0
            while start < segments.count {
                try Task.checkCancellation()
                let end = min(start + batch, segments.count)
                let requests = (start..<end).map {
                    TranslationSession.Request(
                        sourceText: segments[$0], clientIdentifier: String($0))
                }
                for response in try await session.translations(from: requests) {
                    if let id = response.clientIdentifier.flatMap(Int.init) {
                        translated[id] = response.targetText
                    }
                }
                start = end
                progress(Double(end) / Double(segments.count))
            }
            var result = blocks
            var tables: [Int: [[String]]] = [:]
            for (position, owner) in owners.enumerated() {
                if let row = owner.row, let cell = owner.cell {
                    if tables[owner.block] == nil {
                        tables[owner.block] = blocks[owner.block].markdown.split(separator: "\n")
                            .map {
                                IntelligenceSource.tableCells(String($0))
                            }
                    }
                    tables[owner.block]?[row][cell] = translated[position]
                } else {
                    result[owner.block].text = translated[position]
                    result[owner.block].markdown = translated[position]
                }
            }
            for (index, rows) in tables {
                let lines = rows.map { cells -> String in
                    if cells.allSatisfy({ $0.replacingOccurrences(of: "-", with: "").isEmpty }) {
                        return "|" + String(repeating: " --- |", count: cells.count)
                    }
                    return "| " + cells.joined(separator: " | ") + " |"
                }
                result[index].markdown = lines.joined(separator: "\n")
                result[index].text = result[index].markdown
            }
            return result
        }
        #endif
        throw StudioError.unavailable("Translation needs macOS 26 or later.")
    }
}
