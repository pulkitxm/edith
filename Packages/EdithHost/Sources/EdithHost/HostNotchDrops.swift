import AppKit
import Foundation

struct HostNotchPanelDrop: Codable, Equatable, Sendable {
    let identity: HostNotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let fileURLs: [URL]
    let text: String?
    let x: Double?
    let y: Double?
}

struct HostNotchPanelPromise: Codable, Equatable, Sendable {
    let identity: HostNotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let id: UUID
    var fileURL: URL?
    let x: Double?
    let y: Double?
}

@MainActor
protocol HostNotchPromiseSource: AnyObject {
    var fileCount: Int { get }
    func receive(
        at destination: URL, queue: OperationQueue,
        completion: @escaping @Sendable (URL?, Bool) -> Void
    ) -> Int
}

@MainActor
final class HostNotchNativePromiseSource: HostNotchPromiseSource {
    private let receiver: NSFilePromiseReceiver
    init(_ receiver: NSFilePromiseReceiver) { self.receiver = receiver }
    var fileCount: Int { receiver.fileNames.count }
    func receive(
        at destination: URL, queue: OperationQueue,
        completion: @escaping @Sendable (URL?, Bool) -> Void
    ) -> Int {
        receiver.receivePromisedFiles(
            atDestination: destination, options: [:], operationQueue: queue
        ) { url, error in
            completion(error == nil ? url : nil, error != nil)
        }
        return receiver.fileNames.count
    }
}

@MainActor
struct HostNotchDropInput {
    let fileURLs: [URL]
    let text: String?
    let promises: [any HostNotchPromiseSource]

    static func read(_ pasteboard: NSPasteboard) -> Self {
        let receivers =
            pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        if !receivers.isEmpty {
            return .init(
                fileURLs: [], text: nil, promises: receivers.map(HostNotchNativePromiseSource.init))
        }
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return .init(
            fileURLs: urls, text: urls.isEmpty ? pasteboard.string(forType: .string) : nil,
            promises: [])
    }

    func validate() throws {
        guard fileURLs.count <= 32, promises.count <= 32,
            promises.isEmpty || (fileURLs.isEmpty && text == nil),
            !fileURLs.isEmpty || text != nil || !promises.isEmpty,
            text.map({ !$0.isEmpty && $0.utf8.count <= 65536 && !$0.utf8.contains(0) }) ?? true,
            fileURLs.allSatisfy({
                $0.isFileURL && $0.path.utf8.count <= 4096 && !$0.path.utf8.contains(0)
            })
        else { throw HostNotchPanelError.invalidState }
    }
}

@MainActor
final class HostNotchDropProxy {
    private let invoke: HostNotchPanelCoordinator.Invoke
    private let admitted: @MainActor (HostNotchPanelIdentity, UInt32, UUID) -> Bool
    private var drops: [UUID: Task<Void, Never>] = [:]
    private var promises: [UUID: Record] = [:]
    private var retired = false
    private(set) var failure: String?

    init(
        invoke: @escaping HostNotchPanelCoordinator.Invoke,
        admitted: @escaping @MainActor (HostNotchPanelIdentity, UInt32, UUID) -> Bool
    ) {
        self.invoke = invoke; self.admitted = admitted
    }

    var pendingCount: Int { drops.count + promises.count }

    func accept(
        _ input: HostNotchDropInput, identity: HostNotchPanelIdentity,
        displayID: UInt32, presentationID: UUID, point: CGPoint?
    ) throws {
        try input.validate()
        guard !retired, pendingCount < 8, admitted(identity, displayID, presentationID),
            point.map({
                $0.x.isFinite && $0.y.isFinite && (-1200...2400).contains($0.x)
                    && (-1024...2048).contains($0.y)
            }) ?? true
        else { throw HostNotchPanelError.staleState }
        if !input.promises.isEmpty {
            let request = HostNotchPanelPromise(
                identity: identity, displayID: displayID,
                presentationID: presentationID, id: UUID(), x: point.map { Double($0.x) },
                y: point.map { Double($0.y) })
            let record = Record(request: request, sources: input.promises)
            promises[request.id] = record
            record.preparing = Task { [weak self] in
                guard let self else { return }
                defer { record.preparing = nil }
                do {
                    guard !record.cancelled, !retired, admitted(identity, displayID, presentationID)
                    else { throw CancellationError() }
                    let result = try await invoke(
                        "notch.panel.promise.prepare", JSONEncoder().encode(request), 5)
                    record.issued = true
                    guard result.count <= 8192 else { throw HostNotchPanelError.invalidState }
                    let root = try JSONDecoder().decode(URL.self, from: result)
                    record.pins = try HostNotchIssuedFiles(urls: [], root: root)
                    record.root = root
                    guard !record.cancelled, !retired, admitted(identity, displayID, presentationID)
                    else {
                        finish(record); return
                    }
                    record.sourcesStarted = true
                    var expected = 0
                    for source in record.sources {
                        record.startedSources.append(source)
                        let count = source.receive(at: root, queue: record.queue) {
                            [weak self, weak record = record] url, failed in
                            Task { @MainActor in
                                guard let self, let record, self.promises[request.id] === record
                                else {
                                    return
                                }
                                self.received(url, failed: failed, record: record)
                            }
                        }
                        guard count > 0, expected + count <= 32 else {
                            record.expected = nil
                            record.cancelled = true
                            failure =
                                "The file promise did not declare a bounded file count. Its native writer must finish before cleanup."
                            return
                        }
                        expected += count
                    }
                    record.expected = expected
                    if record.receivedCount == expected { finish(record) }
                } catch {
                    record.cancelled = true
                    if record.issued { finish(record) } else { promises[request.id] = nil }
                    failure = "The file promise could not start."
                }
            }
        } else {
            let token = UUID()
            let request = HostNotchPanelDrop(
                identity: identity, displayID: displayID,
                presentationID: presentationID, fileURLs: input.fileURLs, text: input.text,
                x: point.map { Double($0.x) }, y: point.map { Double($0.y) })
            drops[token] = Task { [weak self] in
                guard let self else { return }
                defer { drops[token] = nil }
                do {
                    try Task.checkCancellation()
                    guard admitted(identity, displayID, presentationID) else {
                        throw HostNotchPanelError.staleState
                    }
                    _ = try await invoke("notch.panel.drop", JSONEncoder().encode(request), 5)
                } catch { failure = "The shelf drop did not complete." }
            }
        }
    }

    func cancelPending() {
        for task in drops.values { task.cancel() }
        for record in promises.values {
            record.cancelled = true
            if record.issued,
                record.sourcesStarted == false || record.expected == record.receivedCount
            {
                finish(record)
            }
        }
    }

    func stop() async throws {
        retired = true
        cancelPending()
        for task in Array(drops.values) { await task.value }
        for record in Array(promises.values) {
            if let preparing = record.preparing { await preparing.value }
            if let finishing = record.finishing { await finishing.value }
            if record.issued, record.expected == record.receivedCount { finish(record) }
            if let finishing = record.finishing { await finishing.value }
        }
        guard promises.isEmpty else { throw HostNotchPanelError.staleState }
    }

    private func received(_ url: URL?, failed: Bool, record: Record) {
        record.receivedCount += 1
        if record.results.count < 32 {
            record.results.append(failed ? nil : url)
        } else {
            record.cancelled = true; failure = "The file promise exceeded the native file limit."
        }
        if record.expected == nil {
            let counts = record.startedSources.map(\.fileCount)
            if counts.allSatisfy({ (1...32768).contains($0) }) {
                record.expected = counts.reduce(0, +)
            }
        }
        if record.expected == record.receivedCount { finish(record) }
    }

    private func finish(_ record: Record) {
        guard record.finishing == nil, record.issued,
            !record.sourcesStarted || record.expected == record.receivedCount
        else { return }
        record.finishing = Task { [weak self] in
            guard let self else { return }
            var cleanupNeeded = false
            defer {
                record.finishing = nil
                if cleanupNeeded { finish(record) }
            }
            do {
                if record.requests == nil {
                    var requests = [record.request]
                    if !record.cancelled, !retired,
                        admitted(
                            record.request.identity, record.request.displayID,
                            record.request.presentationID),
                        let root = record.root
                    {
                        try record.pins?.validate()
                        let urls = record.results.compactMap { $0 }
                        guard urls.count == record.results.count, Set(urls).count == urls.count,
                            urls.allSatisfy({
                                $0.isFileURL && $0.standardizedFileURL == $0
                                    && $0.deletingLastPathComponent() == root
                            })
                        else {
                            throw HostNotchPanelError.invalidState
                        }
                        record.receivedPins = try HostNotchIssuedFiles(urls: urls)
                        for url in urls.dropFirst() {
                            var next = record.request
                            next = .init(
                                identity: next.identity, displayID: next.displayID,
                                presentationID: next.presentationID, id: UUID(), x: next.x,
                                y: next.y)
                            let result = try await invoke(
                                "notch.panel.promise.prepare", JSONEncoder().encode(next), 5)
                            guard result.count <= 8192 else {
                                throw HostNotchPanelError.invalidState
                            }
                            let destination = try JSONDecoder().decode(URL.self, from: result)
                            let pins = try HostNotchIssuedFiles(urls: [], root: destination)
                            record.additionalPins.append(pins)
                            record.extraIssued.append(next)
                            try pins.validate()
                            let copy = destination.appendingPathComponent(url.lastPathComponent)
                            try record.receivedPins?.validate()
                            try FileManager.default.copyItem(at: url, to: copy)
                            next.fileURL = copy
                            requests.append(next)
                        }
                        requests[0].fileURL = urls.first
                    }
                    record.requests = requests
                }
                guard let requests = record.requests else { throw HostNotchPanelError.staleState }
                for request in requests where !record.confirmed.contains(request.id) {
                    _ = try await invoke(
                        "notch.panel.promise.finish", JSONEncoder().encode(request), 5)
                    record.confirmed.insert(request.id)
                }
                promises[record.request.id] = nil
                failure = nil
            } catch {
                if record.requests == nil {
                    record.cancelled = true
                    record.requests = [record.request] + record.extraIssued
                    cleanupNeeded = true
                }
                failure = "The file promise is still stopping. Retry cleanup."
            }
        }
    }

    @MainActor
    private final class Record {
        let request: HostNotchPanelPromise
        let sources: [any HostNotchPromiseSource]
        var startedSources: [any HostNotchPromiseSource] = []
        var receivedCount = 0
        let queue = OperationQueue()
        var expected: Int?
        var results: [URL?] = []
        var root: URL?
        var pins: HostNotchIssuedFiles?
        var receivedPins: HostNotchIssuedFiles?
        var additionalPins: [HostNotchIssuedFiles] = []
        var extraIssued: [HostNotchPanelPromise] = []
        var requests: [HostNotchPanelPromise]?
        var confirmed: Set<UUID> = []
        var preparing: Task<Void, Never>?
        var finishing: Task<Void, Never>?
        var issued = false
        var cancelled = false
        var sourcesStarted = false
        init(request: HostNotchPanelPromise, sources: [any HostNotchPromiseSource]) {
            self.request = request; self.sources = sources
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
        }
    }
}
