import EdithExtensionSupport
import Foundation

public enum DataRoot {
    public static let devOverrideVariable = "EDITH_EXTENSION_DATA_ROOT"
    public static var support: URL { ExtensionData.root }
    public static var studio: URL { support.appendingPathComponent("studio", isDirectory: true) }
}
