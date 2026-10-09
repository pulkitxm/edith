import EdithExtensionSupport
import Foundation

public enum ClipboardPaths {
    nonisolated(unsafe) public static var root: URL = ExtensionData.root

    public static var dir: URL {
        root.appendingPathComponent("clipboard")
    }
    public static var indexFile: URL {
        dir.appendingPathComponent("index.jsonl")
    }
    public static var blobsDir: URL {
        dir.appendingPathComponent("blobs")
    }
    public static var lockFile: URL {
        dir.appendingPathComponent(".lock")
    }
    public static func blobFile(sha256: String, ext: String) -> URL {
        blobsDir.appendingPathComponent("\(sha256).\(ext)")
    }
}
