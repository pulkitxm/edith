import Foundation

enum CodeStatsCancellation {
    static func isSilent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError { return url.code == .cancelled }
        let bridged = error as NSError
        return bridged.domain == NSURLErrorDomain && bridged.code == NSURLErrorCancelled
    }
}
