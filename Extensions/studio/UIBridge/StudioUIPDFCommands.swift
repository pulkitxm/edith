import AppKit
import EdithExtensionSupport
import EdithStudio
import Foundation
import PDFKit

struct StudioUIPDFLoad: Codable, Sendable {
    let resource: StudioUIResource?
    let needsPassword: Bool
    let wrongPassword: Bool
    let failure: String?
}

struct StudioUIPDFChange: Codable, Sendable {
    let snapshot: PDFEditSession.Snapshot
    let status: String?
}

struct StudioUISignature: Codable, Sendable {
    let url: URL
    let image: StudioUIImageData
}

struct StudioUIComparison: Codable, Sendable {
    let original: Data
    let revised: Data
    let report: PDFComparison.Report
}

struct StudioUIVisualDifference: Codable, Sendable {
    let image: StudioUIImageData
    let fraction: Double
}

@MainActor enum StudioUIPDFCommands {
    private static let fields: [String: Set<String>] = [
        "studio.ui.pdf.load": ["path", "password"],
        "studio.ui.pdf.change": ["path", "snapshot", "action", "parameters"],
        "studio.ui.pdf.export": ["path", "snapshot", "output", "suffix", "flatten"],
        "studio.ui.pdf.signatures.list": [],
        "studio.ui.pdf.signatures.save": ["image"],
        "studio.ui.pdf.signatures.remove": ["path"],
        "studio.ui.pdf.compare": ["original", "revised"],
        "studio.ui.pdf.visual": ["original", "revised", "page"],
    ]

    static func execute(
        _ operation: String, payload: Data, model: StudioModel,
        resources: StudioUIResources, work: StudioUILongOperations
    ) async throws -> Data {
        guard !model.isStopped, let allowed = fields[operation],
            payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        switch operation {
        case "studio.ui.pdf.load":
            let url = try path(object, "path")
            let password = object["password"] as? String
            guard password?.utf8.count ?? 0 <= 4_096 else {
                throw ExtensionPeerError.invalidRequest
            }
            do {
                let snapshot = try await BlockingWork.perform {
                    guard let snapshot = try PDFEditSession(url: url, password: password).snapshot()
                    else { throw StudioError.unreadable(url.lastPathComponent) }
                    return snapshot
                }
                return try encoder.encode(
                    StudioUIPDFLoad(
                        resource: resources.store(encoder.encode(snapshot)),
                        needsPassword: false, wrongPassword: false, failure: nil))
            } catch let error as StudioError {
                let needsPassword: Bool
                let wrongPassword: Bool
                switch error {
                case .needsPassword: needsPassword = true; wrongPassword = false
                case .wrongPassword: needsPassword = true; wrongPassword = true
                default: needsPassword = false; wrongPassword = false
                }
                return try encoder.encode(
                    StudioUIPDFLoad(
                        resource: nil, needsPassword: needsPassword,
                        wrongPassword: wrongPassword, failure: error.localizedDescription))
            }
        case "studio.ui.pdf.export", "studio.ui.pdf.change":
            let url = try path(object, "path")
            let snapshot: PDFEditSession.Snapshot = try consume(
                object["snapshot"], resources: resources)
            guard let session = PDFEditSession(snapshot: snapshot, source: url) else {
                throw StudioError.unreadable(url.lastPathComponent)
            }
            if operation == "studio.ui.pdf.export" {
                guard let flatten = object["flatten"] as? Bool,
                    let suffix = object["suffix"] as? String,
                    StudioPDFEditorMode.allCases.contains(where: { $0.suffix == suffix })
                else { throw ExtensionPeerError.invalidRequest }
                let target =
                    try (object["output"] as? String).map(StudioCommands.localPath)
                    ?? StudioPDFEditorText.defaultOutput(
                        for: url, suffix: suffix, destination: model.destination)
                return try encoder.encode(
                    work.start { progress in
                        let task = Task.detached(priority: .userInitiated) {
                            try await session.export(
                                to: target, flatten: flatten, progress: progress)
                        }
                        try await withTaskCancellationHandler {
                            try await task.value
                        } onCancel: {
                            task.cancel()
                        }
                        try Task.checkCancellation()
                        model.add([target])
                        model.recordSaved(
                            toolID: "pdf."
                                + (StudioPDFEditorMode.allCases.first(where: { $0.suffix == suffix }
                                )?.rawValue ?? "annotate"), title: "PDF editor", outputs: [target])
                        return try JSONEncoder().encode(target)
                    })
            }
            guard let action = object["action"] as? String,
                let parameters = object["parameters"] as? [String: Any]
            else { throw ExtensionPeerError.invalidRequest }
            let allowed: Set<String>
            switch action {
            case "insert": allowed = ["file", "page"]
            case "extract": allowed = ["pages", "output"]
            case "trim", "fields": allowed = []
            case "redactions": allowed = ["terms", "emails", "phones", "cards"]
            default: throw ExtensionPeerError.invalidRequest
            }
            guard Set(parameters.keys) == allowed else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(
                work.start { _ in
                    let task = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let status: String?
                        switch action {
                        case "insert":
                            guard let page = parameters["page"] as? Int,
                                (0...session.pageCount).contains(page)
                            else {
                                throw ExtensionPeerError.invalidRequest
                            }
                            _ = try session.insertPages(from: path(parameters, "file"), at: page)
                            status = nil
                        case "extract":
                            guard let pages = parameters["pages"] as? [Int], !pages.isEmpty,
                                pages.count <= 50_000,
                                pages.allSatisfy({ (0..<session.pageCount).contains($0) })
                            else { throw ExtensionPeerError.invalidRequest }
                            let target = try path(parameters, "output")
                            try session.extractPages(pages, to: target)
                            status =
                                "Saved \(pages.count) page\(pages.count == 1 ? "" : "s") to \(target.lastPathComponent)."
                        case "trim":
                            let count = try session.trimMargins(pages: Array(0..<session.pageCount))
                            status =
                                count == 0
                                ? "No white margins to trim."
                                : "Trimmed \(count) page\(count == 1 ? "" : "s")."
                        case "fields":
                            let count = session.detectFormFields()
                            status =
                                count == 0
                                ? "No blanks or boxes found to turn into fields."
                                : "Added \(count) field\(count == 1 ? "" : "s")."
                        case "redactions":
                            guard let terms = parameters["terms"] as? String,
                                terms.utf8.count <= 65_536,
                                let emails = parameters["emails"] as? Bool,
                                let phones = parameters["phones"] as? Bool,
                                let cards = parameters["cards"] as? Bool
                            else { throw ExtensionPeerError.invalidRequest }
                            var patterns: [PDFRedaction.Pattern] = []
                            if emails { patterns.append(.email) };
                            if phones { patterns.append(.phone) };
                            if cards { patterns.append(.card) }
                            let count = session.markRedactions(
                                terms: PDFRedaction.terms(from: terms), patterns: patterns)
                            status =
                                count == 0
                                ? "No matches found."
                                : "Marked \(count) match\(count == 1 ? "" : "es")."
                        default: throw ExtensionPeerError.invalidRequest
                        }
                        try Task.checkCancellation()
                        guard let snapshot = session.snapshot() else {
                            throw StudioError.unreadable(url.lastPathComponent)
                        }
                        return StudioUIPDFChange(snapshot: snapshot, status: status)
                    }
                    let value = try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: {
                        task.cancel()
                    }
                    return try JSONEncoder().encode(resources.store(JSONEncoder().encode(value)))
                })
        case "studio.ui.pdf.signatures.list":
            let signatures = try await BlockingWork.perform {
                try StudioSignatureStore.load().map {
                    StudioUISignature(url: $0.url, image: try StudioUIImageData($0.image))
                }
            }
            return try encoder.encode(resources.store(encoder.encode(signatures)))
        case "studio.ui.pdf.signatures.save":
            let data: StudioUIImageData = try consume(object["image"], resources: resources)
            guard let image = data.image else { throw ExtensionPeerError.invalidRequest }
            let signature = try StudioSignatureStore.save(image)
            return try encoder.encode(
                StudioUISignature(url: signature.url, image: StudioUIImageData(signature.image)))
        case "studio.ui.pdf.signatures.remove":
            let url = try path(object, "path").standardizedFileURL
            guard
                url.deletingLastPathComponent()
                    == StudioLibraryStore.signatures.standardizedFileURL,
                url.pathExtension == "png"
            else { throw ExtensionPeerError.invalidRequest }
            try FileManager.default.removeItem(at: url)
            return Data("{}".utf8)
        case "studio.ui.pdf.compare":
            let left = try path(object, "original")
            let right = try path(object, "revised")
            let value = try await BlockingWork.perform {
                let loaded = try StudioCompareLoader.load(left, right).get()
                StudioCompareLoader.highlight(loaded.report, in: loaded.original, loaded.revised)
                guard let original = loaded.original.dataRepresentation(),
                    let revised = loaded.revised.dataRepresentation()
                else { throw StudioError.unreadable("PDF comparison") }
                return StudioUIComparison(
                    original: original, revised: revised, report: loaded.report)
            }
            return try encoder.encode(resources.store(encoder.encode(value)))
        case "studio.ui.pdf.visual":
            let left = try path(object, "original")
            let right = try path(object, "revised")
            guard let page = object["page"] as? Int, page >= 0 else {
                throw ExtensionPeerError.invalidRequest
            }
            let value = try await BlockingWork.perform {
                try StudioCompareLoader.visual(left, right, page: page).map {
                    StudioUIVisualDifference(
                        image: try StudioUIImageData($0.image), fraction: $0.changedFraction)
                }
            }
            return try encoder.encode(resources.store(encoder.encode(value)))
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private nonisolated static func path(_ object: [String: Any], _ key: String) throws -> URL {
        guard let value = object[key] as? String else { throw ExtensionPeerError.invalidRequest }
        return try StudioCommands.localPath(value)
    }

    private static func consume<Value: Decodable>(_ object: Any?, resources: StudioUIResources)
        throws -> Value
    {
        guard let object else { throw ExtensionPeerError.invalidRequest }
        let handle = try JSONDecoder().decode(
            StudioUIResource.self, from: JSONSerialization.data(withJSONObject: object))
        return try JSONDecoder().decode(Value.self, from: resources.consume(handle))
    }
}
