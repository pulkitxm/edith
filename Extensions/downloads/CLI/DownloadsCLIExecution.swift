import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor final class DownloadsCLIRecords {
    var records: [DownloadRecord]
    init(_ records: [DownloadRecord]) { self.records = records }
}
@MainActor enum DownloadsCLIEnvironment {
    @TaskLocal static var worker = DownloadWorker.shared
    @TaskLocal static var storage: DownloadsCLIRecords?
    static var records: [DownloadRecord] {
        get { storage?.records ?? [] }
        set { storage?.records = newValue }
    }
}
@MainActor enum DownloadsCLIExecution {
    private static func bind<Value>(_ worker: DownloadWorker, operation: () async throws -> Value)
        async throws -> Value
    {
        let records = DownloadsCLIRecords(await worker.snapshot().records)
        return try await DownloadsCLIEnvironment.$worker.withValue(worker) {
            try await DownloadsCLIEnvironment.$storage.withValue(records) { try await operation() }
        }
    }
    static func run(_ request: ExtensionCLIRequest, worker: DownloadWorker) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        return try await bind(worker) {
            try await ExtensionCLIExecution.run(DownloadCommand.self, request: request)
        }
    }
    static func stream(
        _ streams: ExtensionCLIStreams, operation: String, payload: Data, worker: DownloadWorker
    ) async throws -> Data {
        try await bind(worker) {
            try streams.invoke(
                DownloadCommand.self, operation: operation, prefix: "downloads.cli",
                payload: payload)
        }
    }

    static func record(at index: Int) throws -> DownloadRecord {
        let records = DownloadsCLIEnvironment.records
        guard !records.isEmpty else { throw DownloadOperationError.empty }
        guard index > 0, index <= records.count else {
            throw DownloadOperationError.missingIndex(index, count: records.count)
        }
        return records[index - 1]
    }
    private static func mutate(_ request: DownloadsMutation) async throws -> DownloadsMutationResult
    {
        let value = try await DownloadsCLIEnvironment.worker.mutate(request)
        DownloadsCLIEnvironment.records = value.records
        return value
    }
    static func enqueue(
        urls: [URL], prefix: String, kind: DownloadKind, file: URL, outputDirectory: URL?,
        browser: DownloadBrowser?
    ) async throws -> [DownloadRecord] {
        try await mutate(
            .enqueue(
                urls: urls, prefix: prefix, kind: kind,
                outputDirectory: outputDirectory ?? MediaDownloadInput.defaultDirectory(for: kind),
                browser: browser)
        ).added
    }
    static func retry(all: Bool, file: URL) async throws -> DownloadMutationResult {
        try await mutate(.retry(id: nil, all: all)).mutation
    }
    static func retry(index: Int, file: URL) async throws -> DownloadMutationResult {
        let record = try record(at: index)
        guard record.canRetry else {
            throw DownloadOperationError.notRetryable(index, state: record.state)
        }
        return try await mutate(.retry(id: record.id, all: false)).mutation
    }
    static func remove(id: UUID, file: URL) async throws -> DownloadMutationResult {
        try await mutate(.remove(id: id)).mutation
    }
    static func clear(file: URL) async throws -> DownloadMutationResult {
        try await mutate(.clear(includeActive: false)).mutation
    }
    static func cancel(index: Int, file: URL) async throws -> DownloadMutationResult {
        let record = try record(at: index)
        guard !record.isFinished else {
            throw DownloadOperationError.notCancelable(index, state: record.state)
        }
        return try await mutate(.cancel(id: record.id, includeQueued: true, reason: "Cancelled"))
            .mutation
    }
    static func cancel(file: URL) async throws -> DownloadMutationResult {
        try await mutate(.cancel(id: nil, includeQueued: true, reason: "Cancelled")).mutation
    }
}
