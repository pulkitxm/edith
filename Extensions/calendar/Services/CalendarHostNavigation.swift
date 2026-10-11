import EdithExtensionSupport
import Foundation

struct CalendarNavigationRequest: Codable, Equatable, Sendable {
    let presentationID: UUID
    let location: String

    func validate() throws {
        guard ["home", "notch"].contains(location) else {
            throw ExtensionPeerError.invalidRequest
        }
    }

    var dictionary: NSDictionary {
        ["section": "calendar", "presentationID": presentationID.uuidString, "location": location]
    }
}

@MainActor final class CalendarHostNavigation {
    private struct Pending {
        var token: NSString?
        let continuation: CheckedContinuation<Void, any Error>
        let deadline: Task<Void, Never>
    }

    private let bridge: NSObject
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false
    private var callbacks: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: Task<Void, Never>] = [:]

    init?(bridge: NSObject?) {
        guard let bridge, bridge.responds(to: NSSelectorFromString("navigate:completion:")),
            bridge.responds(to: NSSelectorFromString("cancelNavigation:"))
        else { return nil }
        self.bridge = bridge
    }

    func navigate(_ request: CalendarNavigationRequest) async throws {
        try request.validate()
        try Task.checkCancellation()
        guard !invalidated, callbacks.count < 8 else { throw ExtensionPeerError.unavailable }
        let id = UUID()
        let canceled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancellations[id] = Task { [self] in
            defer { cancellations[id] = nil }
            for await _ in canceled.stream {
                finish(id, result: .failure(CancellationError()), cancel: true)
            }
        }
        defer { canceled.continuation.finish() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [self] in
                    defer { deadlines[id] = nil }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self.finish(id, result: .failure(ExtensionPeerError.unavailable), cancel: true)
                }
                deadlines[id] = deadline
                pending[id] = Pending(token: nil, continuation: continuation, deadline: deadline)
                let selector = NSSelectorFromString("navigate:completion:")
                typealias Navigate =
                    @convention(c) (
                        AnyObject, Selector, NSDictionary, @convention(block) (NSString?) -> Void
                    ) -> NSString?
                let navigate = unsafeBitCast(bridge.method(for: selector), to: Navigate.self)
                let response = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingNewest(1))
                callbacks[id] = Task { [self] in
                    defer { callbacks[id] = nil }
                    for await message in response.stream {
                        finish(
                            id,
                            result: message.map {
                                .failure(ExtensionPeerError.rejected($0))
                            } ?? .success(()))
                    }
                }
                let completion: @convention(block) (NSString?) -> Void = { message in
                    response.continuation.yield(message as String?)
                    response.continuation.finish()
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
            canceled.continuation.yield(())
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
        invalidate()
        while let task = deadlines.values.first { await task.value }
        while let task = callbacks.values.first { await task.value }
        while let task = cancellations.values.first { await task.value }
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
