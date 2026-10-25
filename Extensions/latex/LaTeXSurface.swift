import EdithExtensionSupport
import Foundation

@MainActor final class LaTeXSurface {
    private let model: LaTeXModel
    private let privacyValues: @MainActor () -> [String: String]

    init(
        model: LaTeXModel,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) { self.model = model; self.privacyValues = privacyValues }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        let request: SurfaceSnapshotRequest
        if command == "surface.perform" {
            request = try SurfaceActionRequest.decode(payload, providerID: "latex").snapshot
        } else {
            request = try SurfaceSnapshotRequest.decode(payload, providerID: "latex")
        }
        return try await SurfaceCommandService.execute(
            providerID: "latex", command: command, payload: payload,
            snapshot: { try await self.snapshot($0) },
            perform: { try await self.perform($0, widget: request.tile.widget) },
            privacyValues: privacyValues)
    }

    private func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        let projects = try model.store.load()
        try Task.checkCancellation()
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        let selected = projects.filter { tile.sourceIDs?.contains($0.id.uuidString) ?? true }
        return .init(
            providerID: "latex",
            metrics: [
                .init("projects", "Documents", "\(selected.count)"),
                .init(
                    "reviews", "Pull requests", "\(selected.filter { $0.pullRequest != nil }.count)"
                ),
            ],
            rows: selected.prefix(tile.itemLimit).map { project in
                .init(
                    project.id.uuidString, title: Self.text(project.name, bytes: 1024),
                    detail: Self.text(
                        project.location == .disk
                            ? URL(fileURLWithPath: project.sourcePath).lastPathComponent
                            : project.repository, bytes: 4096),
                    value: project.pullRequest.map { "PR #\($0)" } ?? project.compiler.title,
                    icon: "doc.richtext",
                    actions: [
                        .init("open/" + project.id.uuidString, "Open document", "arrow.up.right")
                    ])
            },
            sources: projects.prefix(100).map {
                .init($0.id.uuidString, Self.text($0.name, bytes: 1024))
            },
            message: selected.isEmpty ? "Add a LaTeX document to keep it available here." : nil,
            updatedAt: Date())
    }

    private func perform(_ action: String, widget: SurfaceWidget) async throws {
        let parts = action.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])), parts[0] == "open",
            !model.isStopped, try model.store.load().contains(where: { $0.id == id }),
            !SurfacePrivacyState.hides(widget, values: privacyValues())
        else { throw ExtensionPeerError.invalidRequest }
    }

    private static func text(_ value: String, bytes: Int) -> String {
        let cleaned = value.replacingOccurrences(of: "\u{0}", with: "")
        return String(decoding: cleaned.utf8.prefix(bytes - 3), as: UTF8.self)
    }
}
