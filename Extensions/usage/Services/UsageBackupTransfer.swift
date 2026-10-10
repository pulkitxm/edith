import Foundation

func usageBackupTransferLimits(
    localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
    willAcquireDataLock: (() -> Void)? = nil,
    restoreToken: UsageBackupRestoreToken? = nil
) -> Bool {
    do {
        return try usageBackupCoordinateCloud(at: cloudURL, writing: shouldExport) {
            coordinatedCloudURL in
            var cloudData: Data?
            var publication: Data?
            let transferred = try UsageDataTransaction.withExclusiveAccess(
                dataDirectory: localURL.deletingLastPathComponent(),
                willAcquireDataLock: willAcquireDataLock
            ) {
                let localData = try UsageDataFiles.readRegularFile(
                    at: localURL, maximumBytes: UsageDataFiles.maximumLimitsHistoryBytes)
                cloudData = try UsageDataFiles.readRegularFile(
                    at: coordinatedCloudURL,
                    maximumBytes: UsageDataFiles.maximumLimitsHistoryBytes)
                let cloudText = String(decoding: cloudData ?? Data(), as: UTF8.self)
                if shouldRestore, let cloudData, !cloudData.isEmpty,
                    !LimitsHistory.isValidDocument(cloudText)
                {
                    return false
                }
                let merged = LimitsHistory.merge(
                    String(decoding: localData ?? Data(), as: UTF8.self), cloudText)
                guard !merged.isEmpty else {
                    return (localData?.isEmpty ?? true) && (cloudData?.isEmpty ?? true)
                }
                let data = Data(merged.utf8)
                guard data.count <= UsageDataFiles.maximumLimitsHistoryBytes else { return false }
                try Task.checkCancellation()
                try UsageBackupCancellation.current?.check()
                if shouldRestore, localData != data {
                    let prepared = try UsageDataFiles.prepareWrite(data, to: localURL)
                    guard
                        try restoreToken?.performIfValid({
                            try prepared.publish()
                        })
                            ?? {
                                try prepared.publish()
                                return true
                            }()
                    else { return false }
                    try prepared.finish()
                    restoreToken?.recordChange(localURL.lastPathComponent)
                }
                publication = data
                return true
            }
            if transferred, shouldExport, let publication, cloudData != publication {
                try Task.checkCancellation()
                try UsageBackupCancellation.current?.check()
                try publication.write(to: coordinatedCloudURL, options: .atomic)
            }
            return transferred
        }
    } catch {
        return false
    }
}

func usageBackupTransferUsage(
    localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
    willAcquireDataLock: (() -> Void)? = nil,
    restoreToken: UsageBackupRestoreToken? = nil
) -> Bool {
    do {
        return try usageBackupCoordinateCloud(at: cloudURL, writing: shouldExport) {
            coordinatedCloudURL in
            var cloudData: Data?
            var publication: Data?
            let transferred = try UsageDataTransaction.withExclusiveAccess(
                dataDirectory: localURL.deletingLastPathComponent(),
                willAcquireDataLock: willAcquireDataLock
            ) {
                let localData = try UsageDataFiles.readRegularFile(
                    at: localURL, maximumBytes: UsageDataFiles.maximumUsageDocumentBytes)
                cloudData = try UsageDataFiles.readRegularFile(
                    at: coordinatedCloudURL,
                    maximumBytes: UsageDataFiles.maximumUsageDocumentBytes)
                if let localData, !UsageHistory.isValidDocument(localData) {
                    return false
                }
                if let cloudData, !UsageHistory.isValidDocument(cloudData) {
                    return false
                }
                guard let merged = UsageHistory.merge(local: localData, cloud: cloudData) else {
                    return localData == nil && cloudData == nil
                }
                guard merged.count <= UsageDataFiles.maximumUsageDocumentBytes,
                    UsageHistory.isValidDocument(merged)
                else { return false }
                try Task.checkCancellation()
                try UsageBackupCancellation.current?.check()
                if shouldRestore, localData != merged {
                    let prepared = try UsageDataFiles.prepareWrite(merged, to: localURL)
                    guard
                        try restoreToken?.performIfValid({
                            try prepared.publish()
                        })
                            ?? {
                                try prepared.publish()
                                return true
                            }()
                    else { return false }
                    try prepared.finish()
                    restoreToken?.recordChange(localURL.lastPathComponent)
                }
                publication = merged
                return true
            }
            if transferred, shouldExport, let publication, cloudData != publication {
                try Task.checkCancellation()
                try UsageBackupCancellation.current?.check()
                try publication.write(to: coordinatedCloudURL, options: .atomic)
            }
            return transferred
        }
    } catch {
        return false
    }
}

func usageBackupCoordinateCloud<T>(
    at cloudURL: URL, writing: Bool, _ accessor: (URL) throws -> T
) throws -> T {
    try Task.checkCancellation()
    try UsageBackupCancellation.current?.check()
    if writing {
        try FileManager.default.createDirectory(
            at: cloudURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    if !writing, !FileManager.default.fileExists(atPath: cloudURL.path) {
        return try accessor(cloudURL)
    }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    try UsageBackupCancellation.current?.register(coordinator)
    defer { UsageBackupCancellation.current?.unregister() }
    try UsageBackupCancellation.current?.check()
    var result: Result<T, Error>?
    var coordinationError: NSError?
    if writing {
        coordinator.coordinate(
            writingItemAt: cloudURL, options: .forMerging, error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try Task.checkCancellation()
                try UsageBackupCancellation.current?.check()
                return try accessor(coordinatedURL)
            }
        }
    } else {
        coordinator.coordinate(
            readingItemAt: cloudURL, options: .withoutChanges, error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try Task.checkCancellation()
                try UsageBackupCancellation.current?.check()
                return try accessor(coordinatedURL)
            }
        }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return try result.get()
}

func usageBackupCloudFileIsCurrent(_ url: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).icloud")
        return !fm.fileExists(atPath: placeholder.path)
    }
    let values = try? url.resourceValues(
        forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    if values?.isUbiquitousItem == true {
        return values?.ubiquitousItemDownloadingStatus == .current
    }
    return fm.isReadableFile(atPath: url.path)
}

func usageBackupRequestCloudDownload(_ url: URL) {
    do {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    } catch {
        try? FileManager.default.startDownloadingUbiquitousItem(
            at: url.deletingLastPathComponent())
    }
}
