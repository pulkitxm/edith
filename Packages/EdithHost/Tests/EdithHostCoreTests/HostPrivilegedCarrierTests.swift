import EdithExtensionSupport
import Foundation
import Testing
@testable import EdithHostCore

@Suite @MainActor struct HostPrivilegedCarrierTests {
    @Test func rejectedConnectionsAnswerTheCallerInsteadOfLeavingItWaiting() async {
        let delegate = RejectingDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = NSXPCConnection(listenerEndpoint: listener.endpoint)
        client.remoteObjectInterface = NSXPCInterface(with: ExtensionPrivilegedProtocol.self)
        client.resume()
        defer { client.invalidate() }
        let answered = Answer()
        let proxy =
            client.remoteObjectProxyWithErrorHandler { @Sendable _ in answered.finish(true) }
            as? ExtensionPrivilegedProtocol
        proxy?.release { @Sendable _ in answered.finish(true) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            answered.finish(false)
        }
        #expect(await answered.value)
    }

    private final class RejectingDelegate: NSObject, NSXPCListenerDelegate {
        func listener(
            _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
        ) -> Bool {
            let box = HostPrivilegedConnection(connection)
            Task { @MainActor in HostPrivilegedCarrier.reject(box.connection) }
            return true
        }
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?

        var value: Bool {
            get async {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if let result {
                        lock.unlock(); continuation.resume(returning: result)
                    } else {
                        waiter = continuation; lock.unlock()
                    }
                }
            }
        }

        func finish(_ value: Bool) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let next = waiter
            waiter = nil
            lock.unlock()
            next?.resume(returning: value)
        }
    }
}
