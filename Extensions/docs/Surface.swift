import EdithDocsWorker
import EdithExtensionSupport
import Foundation

enum DocsSurface {
    @MainActor
    static func execute(_ command: String, payload: Data, browser: DocsBrowser) async throws -> Data
    {
        try await SurfaceCommandService.execute(
            providerID: "docs", command: command, payload: payload,
            snapshot: { _ in
                await browser.load()
                try Task.checkCancellation()
                return snapshot(library: browser.library, location: browser.location)
            },
            perform: { action in
                guard action.hasPrefix("open:"), let library = browser.library,
                    let page = library.page(String(action.dropFirst(5)))
                else { throw ExtensionPeerError.invalidRequest }
                browser.open(.init(path: page.path))
            })
    }

    static func snapshot(library: DocsLibrary?, location: DocsLocation) -> SurfaceSnapshot {
        guard let library else {
            return .init(providerID: "docs", message: "Documentation is loading.")
        }
        let pages = library.groups.flatMap(\.pages).prefix(100)
        return .init(
            providerID: "docs",
            rows: pages.map { page in
                .init(
                    page.path, sourceID: page.group.isEmpty ? "overview" : page.group,
                    title: String(page.title.prefix(256)),
                    detail: String(page.abstract.prefix(256)),
                    value: page.path == location.path ? "Reading" : "", icon: "doc.text",
                    actions: [.init("open:" + page.path, "Read", "book")])
            },
            sources: Array(library.groups.prefix(100)).map {
                .init($0.id.isEmpty ? "overview" : $0.id, $0.title)
            })
    }
}
