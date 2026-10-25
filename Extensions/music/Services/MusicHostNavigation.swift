import EdithExtensionSupport
import Foundation

struct MusicHostNavigationRequest: Codable, Equatable, Sendable {
    var section: String
    var path: String?
    var presentationID: UUID? = nil
    var location: String? = nil

    func validate() throws {
        guard ["music", "downloads"].contains(section),
            (presentationID == nil) == (location == nil),
            location.map({
                ["main", "home", "notch", "music.footer", "music.sidebar", "music.detail"].contains(
                    $0)
            }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        if let path, !path.isEmpty {
            guard path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\0"),
                !path.contains("\\"),
                path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                })
            else { throw ExtensionPeerError.invalidRequest }
        }
    }

    var dictionary: NSDictionary {
        let value = NSMutableDictionary(dictionary: ["section": section])
        if let path, !path.isEmpty { value["relativePath"] = path }
        if let presentationID { value["presentationID"] = presentationID.uuidString }
        if let location { value["location"] = location }
        return value
    }
}

@MainActor enum MusicHostNavigation {
    static var navigate: ((MusicHostNavigationRequest) async throws -> Void)?
    private(set) static var folderIntent: MusicUIFolderIntent?
    private static var revision: UInt64 = 0
    private static var generation: UInt64 = 0

    static func reset() {
        generation &+= 1; revision = 0; folderIntent = nil
    }

    static func open(
        section: String = "music", path: String? = nil, presentationID: UUID? = nil,
        location: String? = nil
    ) async throws {
        guard ["music", "downloads"].contains(section), let navigate else {
            throw ExtensionPeerError.rejected("Navigation to the owning app window is unavailable.")
        }
        let request = MusicHostNavigationRequest(
            section: section, path: path, presentationID: presentationID, location: location)
        try request.validate()
        let token = generation
        try await navigate(request)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        if section == "music", let path {
            revision &+= 1
            folderIntent = .init(revision: revision, path: path)
        }
    }
}

@MainActor final class MusicHostNavigationBridge {
    private struct Pending {
        var token: NSString?
        let continuation: CheckedContinuation<Void, any Error>
        let deadline: Task<Void, Never>
    }

    private let bridge: NSObject
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false

    init?(bridge: NSObject?) {
        guard let bridge, bridge.responds(to: NSSelectorFromString("navigate:completion:")),
            bridge.responds(to: NSSelectorFromString("cancelNavigation:"))
        else { return nil }
        self.bridge = bridge
    }

    func navigate(_ request: MusicHostNavigationRequest) async throws {
        try request.validate()
        try Task.checkCancellation()
        guard !invalidated, pending.count < 8 else { throw ExtensionPeerError.unavailable }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(id, result: .failure(ExtensionPeerError.unavailable), cancel: true)
                }
                pending[id] = Pending(token: nil, continuation: continuation, deadline: deadline)
                let selector = NSSelectorFromString("navigate:completion:")
                typealias Navigate =
                    @convention(c) (
                        AnyObject, Selector, NSDictionary, @convention(block) (NSString?) -> Void
                    ) -> NSString?
                let navigate = unsafeBitCast(bridge.method(for: selector), to: Navigate.self)
                let completion: @convention(block) (NSString?) -> Void = {
                    @Sendable [weak self] message in
                    let message = message as String?
                    Task { @MainActor [weak self] in
                        self?.finish(
                            id,
                            result: message.map {
                                .failure(ExtensionPeerError.rejected($0))
                            } ?? .success(()))
                    }
                }
                let token = navigate(bridge, selector, request.dictionary, completion)
                if let token, UUID(uuidString: token as String) != nil {
                    pending[id]?.token = token
                } else {
                    finish(id, result: .failure(ExtensionPeerError.unavailable))
                }
                if Task.isCancelled {
                    finish(id, result: .failure(CancellationError()), cancel: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, result: .failure(CancellationError()), cancel: true)
            }
        }
        try Task.checkCancellation()
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for id in Array(pending.keys) {
            finish(id, result: .failure(ExtensionPeerError.unavailable), cancel: true)
        }
    }

    func stopAndWait() async {
        let deadlines = pending.values.map(\.deadline)
        invalidate()
        for task in deadlines { await task.value }
    }

    private func finish(
        _ id: UUID, result: Result<Void, any Error>, cancel: Bool = false
    ) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        if cancel, let token = request.token {
            let selector = NSSelectorFromString("cancelNavigation:")
            typealias Cancel = @convention(c) (AnyObject, Selector, NSString) -> Void
            let cancel = unsafeBitCast(bridge.method(for: selector), to: Cancel.self)
            cancel(bridge, selector, token)
        }
        request.continuation.resume(with: result)
    }
}
