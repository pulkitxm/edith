import EdithExtensionCore
import Foundation

public enum FileCachePaths {
    public static func previewCacheDir(in scope: ExtensionScope) -> URL {
        scope.dataRoot().appendingPathComponent("previews")
    }
}
