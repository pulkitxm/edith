import EdithExtensionSupport
import Foundation

@testable import CleanerExtension

final class CleanerEngineBridge: NSObject {
    let engine: CleanerModel
    var replies: [(operation: String, bytes: Int)] = []

    init(engine: CleanerModel) { self.engine = engine }

    @objc(invoke:completion:) func invoke(
        _ data: NSData, completion: @escaping @Sendable (NSData) -> Void
    ) {
        let request = try! ExtensionEngineWire.decode(
            ExtensionEngineRequest.self, from: data as Data)
        MainActor.assumeIsolated {
            let engine = engine
            Task { @MainActor in
                let reply: ExtensionEngineReply
                do {
                    let payload = try await CleanerUICommands.execute(
                        request.operation, payload: request.payload, model: engine)
                    self.replies.append((request.operation, payload.count))
                    reply = ExtensionEngineReply(token: request.token, ok: true, payload: payload)
                } catch {
                    reply = ExtensionEngineReply(
                        token: request.token, ok: false, payload: Data(),
                        message: String(describing: error))
                }
                completion(try! ExtensionEngineWire.encode(reply) as NSData)
            }
        }
    }

    @objc(cancel:) func cancel(_ token: NSString) {}
}

enum CleanerSyntheticFixture {
    static let words = [
        "atlas", "beacon", "cobalt", "delta", "ember", "fable", "garnet", "harbor", "iris",
        "juniper", "kestrel", "lumen", "meadow", "nimbus", "orchid", "pylon",
    ]
    static let categoryIDs = [
        "nodeModules", "jsBuild", "rustTarget", "swiftBuild", "pyvenv", "pycache", "jsCaches",
        Worktrees.categoryID,
    ]

    static func categories(items total: Int, now: Date = Date()) -> [JunkCategory] {
        var buckets: [String: [JunkItem]] = [:]
        for index in 0..<total {
            let id = categoryIDs[index % categoryIDs.count]
            let project =
                "\(words[index % words.count])-\(words[(index / 7) % words.count])-\(index)"
            let path = URL(fileURLWithPath: "/synthetic/code/\(project)/\(id)")
            let worktree =
                id == Worktrees.categoryID
                ? WorktreeInfo(
                    branch: "feature/\(project)", repository: "/synthetic/code/repo",
                    dirty: false, unpushed: index % 3, merged: index % 5 == 0) : nil
            buckets[id, default: []].append(
                JunkItem(
                    id: path.path, name: "~/code/\(project)/\(id)", path: path,
                    sizeBytes: Int64(4_096 * (index % 97 + 1)), selected: index % 4 == 0,
                    lastModified: now.addingTimeInterval(-Double(index % 40) * 86_400),
                    worktree: worktree))
        }
        return categoryIDs.compactMap { id in
            buckets[id].map {
                JunkCategory(id: id, name: id, detail: "Synthetic \(id) folders", items: $0)
            }
        }
    }

    @MainActor static func engine(
        items: Int, defaults: UserDefaults
    ) async -> CleanerModel {
        let categories = categories(items: items)
        let engine = CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { [] }, scan: { _, _, _ in CleanerScanResult(categories: categories) }))
        engine.scan()
        await engine.finishWork()
        return engine
    }
}
