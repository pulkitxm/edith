import Darwin
import Foundation

public enum BlitzTreeActions {
    public static func trash(
        _ entry: BlitzTreeReport.Entry, root: String, isCancelled: () -> Bool = { false }
    ) throws {
        try trash(entry, root: root, isCancelled: isCancelled) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func trash(
        _ entry: BlitzTreeReport.Entry, root: String, isCancelled: () -> Bool = { false },
        move: (URL) throws -> Void
    ) throws {
        if isCancelled() { throw CancellationError() }
        let url = URL(fileURLWithPath: entry.path)
        let prefix = root == "/" ? "/" : root + "/"
        guard !entry.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
            entry.path == url.path, entry.path != root, entry.path.hasPrefix(prefix),
            try BlitzTreeScanner.resolvedDirectory(url.deletingLastPathComponent().path)
                == url.deletingLastPathComponent().path
        else { throw BlitzTreeError.failed("This item is outside the scanned folder. Scan again.") }
        var metadata = stat()
        guard lstat(entry.path, &metadata) == 0,
            metadata.st_dev == entry.device, metadata.st_ino == entry.inode
        else {
            throw BlitzTreeError.failed(
                "This item changed since the scan. Scan again before removing it.")
        }
        if isCancelled() { throw CancellationError() }
        try move(url)
    }
}
