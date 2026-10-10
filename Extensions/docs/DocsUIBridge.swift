import AppKit
import EdithDocsWorker
import EdithExtensionSupport
import Foundation

struct DocsPresentationPick: Hashable, Identifiable {
    let command: DocsCommand
    let probability: Double
    var id: String { command.path }
}

struct DocsPresentationAnswer: Equatable {
    let request: String
    let engine: DocsAskEngine
    let picks: [DocsPresentationPick]
    let milliseconds: Int

    init(request: String, engine: DocsAskEngine, picks: [DocsPresentationPick], milliseconds: Int) {
        self.request = request
        self.engine = engine
        self.picks = picks
        self.milliseconds = milliseconds
    }

    init(_ answer: DocsAnswer) {
        self.init(
            request: answer.request, engine: answer.engine,
            picks: answer.picks.map {
                DocsPresentationPick(command: $0.command, probability: $0.probability)
            },
            milliseconds: answer.milliseconds)
    }
}

struct DocsAnswerWire: Codable {
    struct Pick: Codable {
        let path: String
        let probability: Double
    }
    let request: String
    let engine: DocsAskEngine
    let picks: [Pick]
    let milliseconds: Int
}

@MainActor struct DocsUIBridge {
    let invoke: (String, Data) async throws -> Data

    init(client: ExtensionEngineClient) {
        invoke = { try await client.invoke($0, payload: $1) }
    }

    init(invoke: @escaping (String, Data) async throws -> Data) { self.invoke = invoke }

    func library() async throws -> DocsLibrary {
        let data = try await invoke("docs.ui.library", Data("{}".utf8))
        let sources = try JSONDecoder().decode([DocsSource].self, from: data)
        try Task.checkCancellation()
        return DocsLibrary(sources: sources)
    }

    func answer(_ request: String, library: DocsLibrary) async throws -> DocsPresentationAnswer {
        let data = try await invoke("docs.ui.ask", JSONEncoder().encode(request))
        let answer = try JSONDecoder().decode(DocsAnswerWire.self, from: data)
        guard answer.request == request else { throw ExtensionPeerError.invalidRequest }
        return DocsPresentationAnswer(
            request: answer.request, engine: answer.engine,
            picks: answer.picks.compactMap { pick in
                library.command(pick.path).map {
                    DocsPresentationPick(command: $0, probability: pick.probability)
                }
            }, milliseconds: answer.milliseconds)
    }

    func follow(_ url: URL) async throws {
        _ = try await invoke("docs.ui.follow", JSONEncoder().encode(url))
    }

    static func execute(_ command: String, payload: Data, browser: DocsBrowser) async throws -> Data
    {
        switch command {
        case "docs.ui.library":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            await browser.load()
            try Task.checkCancellation()
            guard let library = browser.library else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(
                library.pages.map { DocsSource(path: $0.path, markdown: $0.markdown) })
        case "docs.ui.ask":
            let request = try JSONDecoder().decode(String.self, from: payload)
            guard !request.isEmpty, request.utf8.count <= 4096 else {
                throw ExtensionPeerError.invalidRequest
            }
            await browser.load()
            guard let library = browser.library else { throw ExtensionPeerError.unavailable }
            let answer = await DocsAsk.answer(
                request, in: library, decider: DocsPeerDecider.configured(),
                defaults: SharedDefaults.store)
            try Task.checkCancellation()
            return try JSONEncoder().encode(
                DocsAnswerWire(
                    request: answer.request, engine: answer.engine,
                    picks: answer.picks.map {
                        .init(path: $0.command.path, probability: $0.probability)
                    }, milliseconds: answer.milliseconds))
        case "docs.ui.follow":
            let url = try JSONDecoder().decode(URL.self, from: payload)
            guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                url.absoluteString.utf8.count <= 4096
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(NSWorkspace.shared.open(url))
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
