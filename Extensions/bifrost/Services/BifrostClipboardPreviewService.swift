import EdithExtensionSupport
import Foundation

@MainActor final class BifrostClipboardPreviewService {
    static let shared = BifrostClipboardPreviewService()
    typealias Send = @Sendable (String, Data) async throws -> Data
    private let send: Send
    private let privacy: @MainActor () -> [String: String]
    private var reads: [UUID: Task<Data?, Never>] = [:]
    private var cancellations: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    init(
        send: @escaping Send = { command, payload in
            try await BifrostPeers.invoke(owner: "clipboard", command: command, payload: payload)
        },
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) { self.send = send; self.privacy = privacy }

    func load(_ entryID: String) async -> Data? {
        guard !stopped, !entryID.isEmpty, entryID.utf8.count <= 512,
            reads.count < 16, !SurfacePrivacyState.hides(.ability("clipboard"), values: privacy())
        else { return nil }
        struct Request: Encodable { let id: UUID; let entryID: String }
        struct Response: Decodable { let data: Data? }
        let id = UUID()
        let send = self.send
        let task = Task<Data?, Never> {
            do {
                let response = try await send(
                    "clipboard.thumbnail", JSONEncoder().encode(Request(id: id, entryID: entryID)))
                guard response.count <= 180_000, !Task.isCancelled else { return nil }
                guard let data = try JSONDecoder().decode(Response.self, from: response).data else {
                    return nil
                }
                try SurfaceThumbnail(data: data).validate()
                return data
            } catch { return nil }
        }
        reads[id] = task
        defer { reads[id] = nil }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        guard !stopped, !Task.isCancelled,
            !SurfacePrivacyState.hides(.ability("clipboard"), values: privacy())
        else { return nil }
        return value
    }

    private func cancel(_ id: UUID) {
        guard (!stopped || reads[id] != nil), cancellations[id] == nil, cancellations.count < 32
        else { return }
        let send = self.send
        cancellations[id] = Task { [weak self] in
            defer { self?.cancellations[id] = nil }
            _ = try? await send("clipboard.thumbnail.cancel", JSONEncoder().encode(id))
        }
    }

    func resume() { stopped = false }
    func shutdown() async {
        stopped = true
        let active = reads
        for (id, task) in active { task.cancel(); cancel(id) }
        for task in active.values { _ = await task.value }
        for task in Array(cancellations.values) { await task.value }
        reads.removeAll(); cancellations.removeAll()
    }
}
