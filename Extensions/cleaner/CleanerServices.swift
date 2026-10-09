import EdithExtensionSupport
import Foundation

final class CleanerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct CleanerServices: Sendable {
    var drives: @Sendable () async -> [DriveInfo] = {
        await BlockingWork.value { JunkScanner.drives() }
    }
    var scan:
        @Sendable (
            [URL], CleanerCancellation, @escaping @Sendable (String) -> Void
        ) async -> CleanerScanResult = { roots, cancellation, progress in
            await BlockingWork.value {
                CleanerOperationExecution.scan(
                    entries: JunkCatalog.entries, roots: roots,
                    isCancelled: { cancellation.isCancelled }, progress: progress)
            }
        }
    var clean: @Sendable ([JunkItem], CleanerCancellation) async -> CleanerCleanResult = {
        items, cancellation in
        await BlockingWork.value {
            CleanerOperationExecution.clean(items) { selected in
                JunkScanner.clean(selected, isCancelled: { cancellation.isCancelled })
            }
        }
    }
}
