import EdithExtensionSupport
import Foundation

public enum FileCachePaths {
    nonisolated(unsafe) public static var root: URL = ExtensionData.root

    public static var previewCacheDir: URL {
        root.appendingPathComponent("previews")
    }
}
