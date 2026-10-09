import Foundation

final class SEOAuditHTTPClient: @unchecked Sendable {
    private let delegate = Delegate()
    private let session: URLSession
    private let lock = NSLock()
    private var stopped = false

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { shutdown() }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        guard Self.allowed(request.url), maximumBytes > 0, maximumBytes <= 25 * 1_024 * 1_024 else {
            throw SEOAuditInputError("Unsupported site request.")
        }
        let waiter = Waiter()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !stopped else { return nil }
                    let task = session.dataTask(with: request)
                    delegate.add(task, maximumBytes: maximumBytes, continuation: continuation)
                    return task
                }
                guard let task else { continuation.resume(throwing: CancellationError()); return }
                waiter.start(task)
            }
        } onCancel: {
            waiter.cancel()
        }
    }

    func shutdown() {
        let needsShutdown = lock.withLock { () -> Bool in
            guard !stopped else { return false }; stopped = true; return true
        }
        guard needsShutdown else { return }
        delegate.finishAll(); session.invalidateAndCancel()
    }

    static func allowed(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            url.absoluteString.utf8.count <= 4_096
        else { return false }
        return true
    }

    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func start(_ task: URLSessionDataTask) {
            lock.withLock {
                self.task = task
                if cancelled { task.cancel() } else { task.resume() }
            }
        }
        func cancel() {
            lock.withLock {
                cancelled = true; task?.cancel()
            }
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Flight {
            let task: URLSessionDataTask
            let maximumBytes: Int
            let continuation: CheckedContinuation<(Data, URLResponse), Error>
            var bytes = Data()
            var response: URLResponse?
        }
        private let lock = NSLock()
        private var flights: [Int: Flight] = [:]

        func add(
            _ task: URLSessionDataTask, maximumBytes: Int,
            continuation: CheckedContinuation<(Data, URLResponse), Error>
        ) {
            lock.withLock {
                flights[task.taskIdentifier] = Flight(
                    task: task, maximumBytes: maximumBytes, continuation: continuation)
            }
        }
        func finishAll() {
            let pending = lock.withLock {
                let pending = flights; flights.removeAll(); return pending
            }
            for flight in pending.values {
                flight.task.cancel(); flight.continuation.resume(throwing: CancellationError())
            }
        }
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if SEOAuditHTTPClient.allowed(request.url) {
                completionHandler(request)
            } else {
                completionHandler(nil);
                finish(
                    task.taskIdentifier, error: SEOAuditInputError("Unsupported site redirect."));
                task.cancel()
            }
        }
        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let accepted = lock.withLock { () -> Bool in
                guard var flight = flights[dataTask.taskIdentifier],
                    SEOAuditHTTPClient.allowed(response.url),
                    response.expectedContentLength <= flight.maximumBytes
                else { return false }
                flight.response = response; flights[dataTask.taskIdentifier] = flight; return true
            }
            completionHandler(accepted ? .allow : .cancel)
            if !accepted { finish(dataTask.taskIdentifier, error: CocoaError(.fileReadTooLarge)) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
        {
            let accepted = lock.withLock { () -> Bool in
                guard var flight = flights[dataTask.taskIdentifier],
                    data.count <= flight.maximumBytes - flight.bytes.count
                else { return false }
                flight.bytes.append(data); flights[dataTask.taskIdentifier] = flight; return true
            }
            if !accepted {
                finish(dataTask.taskIdentifier, error: CocoaError(.fileReadTooLarge));
                dataTask.cancel()
            }
        }
        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) { finish(task.taskIdentifier, error: error) }
        private func finish(_ id: Int, error: Error?) {
            guard let flight = lock.withLock({ flights.removeValue(forKey: id) }) else { return }
            if let error {
                flight.continuation.resume(throwing: error)
            } else if let response = flight.response {
                flight.continuation.resume(returning: (flight.bytes, response))
            } else {
                flight.continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}
