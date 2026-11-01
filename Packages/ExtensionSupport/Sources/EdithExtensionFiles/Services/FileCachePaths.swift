import EdithExtensionCore
import Foundation

public enum FileCachePaths {
    nonisolated(unsafe) public static var root: URL = ExtensionScope.installed.dataRoot()

    public static var previewCacheDir: URL {
        root.appendingPathComponent("previews")
    }
}
