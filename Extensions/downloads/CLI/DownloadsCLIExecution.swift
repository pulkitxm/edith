import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum DownloadsCLIEnvironment {
    static var worker = DownloadWorker.shared
    static var records: [DownloadRecord] = []
}

@MainActor enum DownloadsCLIExecution {
    static func run(_ request: ExtensionCLIRequest, worker: DownloadWorker) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        let old = DownloadsCLIEnvironment.worker
        let oldRecords = DownloadsCLIEnvironment.records
        DownloadsCLIEnvironment.worker = worker
        DownloadsCLIEnvironment.records = await worker.snapshot().records
        defer { DownloadsCLIEnvironment.worker = old; DownloadsCLIEnvironment.records = oldRecords }
        return try await ExtensionCLIExecution.run(
            DownloadCommand.self, arguments: request.arguments)
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
